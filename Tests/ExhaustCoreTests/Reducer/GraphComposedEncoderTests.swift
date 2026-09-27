import Testing
@testable import ExhaustCore

@Suite("GraphComposedEncoder")
struct GraphComposedEncoderTests {
    // MARK: - Upstream × Downstream Iteration

    @Test("Composition emits downstream probes for each upstream probe")
    func downstreamPerUpstream() {
        let tree = ChoiceTree.group([
            .choice(ChoiceValue(10 as UInt64, tag: .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
        ])
        let graph = ChoiceGraph.build(from: tree)
        let sequence = ChoiceSequence.flatten(tree)

        guard let scope = minimizationScope(tree: tree, graph: graph, sequence: sequence) else {
            Issue.record("No minimization scope")
            return
        }

        var composed = GraphComposedEncoder(
            name: .composed,
            upstream: .binarySearch(GraphBinarySearchEncoder()),
            upstreamScope: scope,
            downstream: .binarySearch(GraphBinarySearchEncoder()),
            upstreamBudget: 100,
            lift: { candidate, _, parent in
                EncoderInput(
                    transformation: parent.transformation,
                    baseSequence: candidate,
                    tree: parent.tree,
                    graph: parent.graph,
                    warmStartRecords: [:]
                )
            }
        )

        composed.start(scope: scope)
        var probeCount = 0
        var buffer = sequence
        while composed.nextProbe(into: &buffer, lastAccepted: false) != nil {
            probeCount += 1
        }

        #expect(probeCount > 5, "Composition of two binary-search encoders over 0...100 should emit more than 5 probes")
    }

    @Test("Composition can build another composition downstream")
    func recursiveDownstreamComposition() throws {
        let tree = ChoiceTree.group([
            .choice(ChoiceValue(10 as UInt64, tag: .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
        ])
        let graph = ChoiceGraph.build(from: tree)
        let sequence = ChoiceSequence.flatten(tree)

        guard let scope = minimizationScope(tree: tree, graph: graph, sequence: sequence) else {
            Issue.record("No minimization scope")
            return
        }

        var downstreamBuildCount = 0
        var nestedScopes: [EncoderInput] = []
        var composed = GraphComposedEncoder(
            name: .composed,
            upstream: .binarySearch(GraphBinarySearchEncoder()),
            upstreamScope: scope,
            upstreamBudget: 2,
            downstreamBuilder: { candidate, _, parent in
                downstreamBuildCount += 1
                let nestedScope = EncoderInput(
                    transformation: parent.transformation,
                    baseSequence: candidate,
                    tree: parent.tree,
                    graph: parent.graph,
                    warmStartRecords: [:]
                )
                nestedScopes.append(nestedScope)
                return (.composed(nestedComposition(scope: nestedScope)), nestedScope)
            }
        )

        composed.start(scope: scope)
        var buffer = sequence
        guard let mutation = composed.nextProbe(into: &buffer, lastAccepted: false) else {
            Issue.record("Expected a recursively composed probe")
            return
        }

        #expect(downstreamBuildCount == 1)
        guard case let .leafValues(changes) = mutation else {
            Issue.record("Expected leafValues mutation, got \(mutation)")
            return
        }
        #expect(changes.count == 1)
        #expect(changes[0].mayReshape)

        var emittedCandidates = [buffer]
        while composed.nextProbe(into: &buffer, lastAccepted: false) != nil {
            emittedCandidates.append(buffer)
        }
        let firstNestedScope = try #require(nestedScopes.first)
        var standaloneNested = nestedComposition(scope: firstNestedScope)
        standaloneNested.start(scope: firstNestedScope)
        let nestedCandidates = drainCandidates(of: &standaloneNested, sequence: firstNestedScope.baseSequence)
        #expect(nestedCandidates.isEmpty == false)
        #expect(Array(emittedCandidates.prefix(nestedCandidates.count)) == nestedCandidates)
    }

    @Test("Downstream builds total every builder call across nesting levels, including failed builds")
    func downstreamBuildsCountNestedAndFailedBuilds() throws {
        let scope = try #require(singleLeafScope(value: 100))
        var outerBuilds = 0
        var nestedBuilds = 0
        var composed = GraphComposedEncoder(
            name: .composed,
            upstream: .binarySearch(GraphBinarySearchEncoder()),
            upstreamScope: scope,
            upstreamBudget: 3,
            probesPerStageTurn: 1,
            downstreamBuilder: { candidate, _, _ in
                outerBuilds += 1
                // Every other outer build fails, as a lift rejected after materializing would.
                guard outerBuilds.isMultiple(of: 2) == false,
                      let liftedValue = candidate.compactMap({ $0.value?.choice.bitPattern64 }).first,
                      let nestedScope = singleLeafScope(value: liftedValue)
                else {
                    return nil
                }
                let nested = GraphComposedEncoder(
                    name: .composed,
                    upstream: .binarySearch(GraphBinarySearchEncoder()),
                    upstreamScope: nestedScope,
                    upstreamBudget: 2,
                    downstreamBuilder: { nestedCandidate, _, _ in
                        nestedBuilds += 1
                        guard let nestedValue = nestedCandidate.compactMap({ $0.value?.choice.bitPattern64 }).first else {
                            return nil
                        }
                        return singleLeafScope(value: nestedValue).map { (.binarySearch(GraphBinarySearchEncoder()), $0) }
                    }
                )
                return (.composed(nested), nestedScope)
            }
        )

        composed.start(scope: scope)
        var buffer = scope.baseSequence
        var probeCount = 0
        while composed.nextProbe(into: &buffer, lastAccepted: false) != nil {
            probeCount += 1
            if probeCount == 5 {
                composed.refreshState(graph: scope.graph, sequence: buffer)
            }
        }

        #expect(probeCount >= 5)
        #expect(outerBuilds > 1)
        #expect(nestedBuilds > 0)
        #expect(composed.downstreamBuilds == outerBuilds + nestedBuilds)
    }

    // MARK: - Stage Turns

    @Test("Each stage emits one turn of probes before the next stage starts, and suspended stages resume oldest first")
    func stageTurnsRotateStages() throws {
        let grouped = try stageProbes(probesPerStageTurn: nil)
        let interleaved = try stageProbes(probesPerStageTurn: 2)

        var stages: [UInt64] = []
        for probe in grouped where stages.contains(probe.stage) == false {
            stages.append(probe.stage)
        }
        try #require(stages.count == 3)
        let first = stages[0]
        let second = stages[1]
        let third = stages[2]
        try #require(grouped.count(where: { $0.stage == first }) >= 4)

        #expect(interleaved.prefix(6).map(\.stage) == [first, first, second, second, third, third])
        #expect(interleaved.dropFirst(6).prefix(2).map(\.stage) == [first, first])
        #expect(longestRun(of: interleaved.map(\.stage)) <= 2)
        for stage in stages {
            #expect(
                interleaved.filter { $0.stage == stage }.map(\.candidate)
                    == grouped.filter { $0.stage == stage }.map(\.candidate),
                "Stage \(stage) must emit the same probes in the same order with or without turns"
            )
        }
    }

    // MARK: - Budget Enforcement

    @Test("Composition stops pulling upstream after budget is exhausted")
    func budgetEnforcement() {
        let tree = ChoiceTree.group([
            .choice(ChoiceValue(50 as UInt64, tag: .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
        ])
        let graph = ChoiceGraph.build(from: tree)
        let sequence = ChoiceSequence.flatten(tree)

        guard let scope = minimizationScope(tree: tree, graph: graph, sequence: sequence) else {
            Issue.record("No minimization scope")
            return
        }

        let unlimitedProbes = drainProbes(
            scope: scope,
            sequence: sequence,
            upstreamBudget: 100
        )

        let limitedProbes = drainProbes(
            scope: scope,
            sequence: sequence,
            upstreamBudget: 1
        )

        #expect(limitedProbes < unlimitedProbes, "Budget=1 should emit fewer probes than budget=100")
        #expect(limitedProbes > 0, "Budget=1 should still emit at least one probe")
    }

    // MARK: - Total Probe Cap

    @Test("Total probe cap stops emission at exactly the cap; zero means unlimited")
    func totalProbeCapBinds() {
        let tree = ChoiceTree.group([
            .choice(ChoiceValue(50 as UInt64, tag: .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
        ])
        let graph = ChoiceGraph.build(from: tree)
        let sequence = ChoiceSequence.flatten(tree)

        guard let scope = minimizationScope(tree: tree, graph: graph, sequence: sequence) else {
            Issue.record("No minimization scope")
            return
        }

        let cap = 3
        let uncappedProbes = drainProbes(
            scope: scope,
            sequence: sequence,
            upstreamBudget: 100
        )
        #expect(uncappedProbes > cap, "The uncapped composition must emit more than the cap for the capped comparison to be meaningful")

        let cappedProbes = drainProbes(
            scope: scope,
            sequence: sequence,
            upstreamBudget: 100,
            totalProbeCap: cap
        )
        #expect(cappedProbes == cap, "A capped composition should emit exactly the cap when the uncapped run exceeds it")
    }

    // MARK: - Lift Failure

    @Test("Failed lifts are skipped without counting against budget")
    func liftFailureSkipped() {
        let tree = ChoiceTree.group([
            .choice(ChoiceValue(20 as UInt64, tag: .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
        ])
        let graph = ChoiceGraph.build(from: tree)
        let sequence = ChoiceSequence.flatten(tree)

        guard let scope = minimizationScope(tree: tree, graph: graph, sequence: sequence) else {
            Issue.record("No minimization scope")
            return
        }

        var liftCallCount = 0
        var composed = GraphComposedEncoder(
            name: .composed,
            upstream: .binarySearch(GraphBinarySearchEncoder()),
            upstreamScope: scope,
            downstream: .binarySearch(GraphBinarySearchEncoder()),
            upstreamBudget: 2,
            lift: { candidate, _, parent in
                liftCallCount += 1
                if liftCallCount % 2 == 0 { return nil }
                return EncoderInput(
                    transformation: parent.transformation,
                    baseSequence: candidate,
                    tree: parent.tree,
                    graph: parent.graph,
                    warmStartRecords: [:]
                )
            }
        )

        composed.start(scope: scope)
        var probeCount = 0
        var buffer = sequence
        while composed.nextProbe(into: &buffer, lastAccepted: false) != nil {
            probeCount += 1
        }

        #expect(liftCallCount > 2, "Failed lifts should cause additional upstream pulls beyond the budget count")
        #expect(probeCount > 0, "Should still emit probes from successful lifts")
    }

    // MARK: - Mutation Wrapping

    @Test("Composition wraps downstream mutation with mayReshape true")
    func mutationWrapping() {
        let tree = ChoiceTree.group([
            .choice(ChoiceValue(30 as UInt64, tag: .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
        ])
        let graph = ChoiceGraph.build(from: tree)
        let sequence = ChoiceSequence.flatten(tree)

        guard let scope = minimizationScope(tree: tree, graph: graph, sequence: sequence) else {
            Issue.record("No minimization scope")
            return
        }

        var composed = GraphComposedEncoder(
            name: .composed,
            upstream: .binarySearch(GraphBinarySearchEncoder()),
            upstreamScope: scope,
            downstream: .binarySearch(GraphBinarySearchEncoder()),
            upstreamBudget: 5,
            lift: { candidate, _, parent in
                EncoderInput(
                    transformation: parent.transformation,
                    baseSequence: candidate,
                    tree: parent.tree,
                    graph: parent.graph,
                    warmStartRecords: [:]
                )
            }
        )

        composed.start(scope: scope)
        var buffer = sequence
        guard let mutation = composed.nextProbe(into: &buffer, lastAccepted: false) else {
            Issue.record("Expected at least one probe")
            return
        }

        guard case let .leafValues(changes) = mutation else {
            Issue.record("Expected leafValues mutation, got \(mutation)")
            return
        }
        #expect(changes.isEmpty == false)
        let allReshape = changes.allSatisfy(\.mayReshape)
        #expect(allReshape, "Composed mutations should have mayReshape set to true")
    }

    // MARK: - refreshState Aborts In-Flight

    @Test("refreshState resets composition so no further probes are emitted")
    func refreshStateResetsComposition() {
        let tree = ChoiceTree.group([
            .choice(ChoiceValue(40 as UInt64, tag: .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
        ])
        let graph = ChoiceGraph.build(from: tree)
        let sequence = ChoiceSequence.flatten(tree)

        guard let scope = minimizationScope(tree: tree, graph: graph, sequence: sequence) else {
            Issue.record("No minimization scope")
            return
        }

        var composed = GraphComposedEncoder(
            name: .composed,
            upstream: .binarySearch(GraphBinarySearchEncoder()),
            upstreamScope: scope,
            downstream: .binarySearch(GraphBinarySearchEncoder()),
            upstreamBudget: 10,
            lift: { candidate, _, parent in
                EncoderInput(
                    transformation: parent.transformation,
                    baseSequence: candidate,
                    tree: parent.tree,
                    graph: parent.graph,
                    warmStartRecords: [:]
                )
            }
        )

        composed.start(scope: scope)
        var buffer = sequence
        _ = composed.nextProbe(into: &buffer, lastAccepted: false)

        composed.refreshState(graph: graph, sequence: sequence)
        let afterRefresh = composed.nextProbe(into: &buffer, lastAccepted: false)
        #expect(afterRefresh == nil, "No probes should be emitted after refreshState")
    }

    // MARK: - Convergence Records

    @Test("Composition exposes upstream convergence records")
    func upstreamConvergenceExposed() {
        let tree = ChoiceTree.group([
            .choice(ChoiceValue(10 as UInt64, tag: .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
        ])
        let graph = ChoiceGraph.build(from: tree)
        let sequence = ChoiceSequence.flatten(tree)

        guard let scope = minimizationScope(tree: tree, graph: graph, sequence: sequence) else {
            Issue.record("No minimization scope")
            return
        }

        var composed = GraphComposedEncoder(
            name: .composed,
            upstream: .value(GraphValueEncoder()),
            upstreamScope: scope,
            downstream: .binarySearch(GraphBinarySearchEncoder()),
            upstreamBudget: 100,
            lift: { candidate, _, parent in
                EncoderInput(
                    transformation: parent.transformation,
                    baseSequence: candidate,
                    tree: parent.tree,
                    graph: parent.graph,
                    warmStartRecords: [:]
                )
            }
        )

        composed.start(scope: scope)
        var buffer = sequence
        var accepted = false
        while composed.nextProbe(into: &buffer, lastAccepted: accepted) != nil {
            accepted = true
        }
        composed.flushPartialConvergence()

        let records = composed.convergenceRecords
        #expect(records.isEmpty == false, "Upstream value encoder should produce convergence records")
    }
}

// MARK: - Helpers

private func drainProbes(
    scope: EncoderInput,
    sequence: ChoiceSequence,
    upstreamBudget: Int,
    totalProbeCap: Int = 0
) -> Int {
    var composed = GraphComposedEncoder(
        name: .composed,
        upstream: .binarySearch(GraphBinarySearchEncoder()),
        upstreamScope: scope,
        downstream: .binarySearch(GraphBinarySearchEncoder()),
        upstreamBudget: upstreamBudget,
        totalProbeCap: totalProbeCap,
        lift: { candidate, _, parent in
            EncoderInput(
                transformation: parent.transformation,
                baseSequence: candidate,
                tree: parent.tree,
                graph: parent.graph,
                warmStartRecords: [:]
            )
        }
    )

    composed.start(scope: scope)
    var count = 0
    var buffer = sequence
    while composed.nextProbe(into: &buffer, lastAccepted: false) != nil {
        count += 1
    }
    return count
}

private func minimizationScope(
    tree: ChoiceTree,
    graph: ChoiceGraph,
    sequence: ChoiceSequence
) -> EncoderInput? {
    let scopes = MinimizationQuery.build(graph: graph)
    guard let firstScope = scopes.first else { return nil }
    let transformation = GraphTransformation(
        operation: .minimize(firstScope),
        priority: DispatchPriority(
            structuralBenefit: 0,
            valueBenefit: 0,
            reductionMagnitude: 0,
            estimatedCost: 10
        )
    )
    return EncoderInput(
        transformation: transformation,
        baseSequence: sequence,
        tree: tree,
        graph: graph,
        warmStartRecords: [:]
    )
}

/// A composition over the scope's single leaf whose downstream re-searches the lifted candidate.
private func nestedComposition(scope: EncoderInput) -> GraphComposedEncoder {
    GraphComposedEncoder(
        name: .composed,
        upstream: .binarySearch(GraphBinarySearchEncoder()),
        upstreamScope: scope,
        downstream: .binarySearch(GraphBinarySearchEncoder()),
        upstreamBudget: 2,
        lift: { candidate, _, parent in
            EncoderInput(
                transformation: parent.transformation,
                baseSequence: candidate,
                tree: parent.tree,
                graph: parent.graph,
                warmStartRecords: [:]
            )
        }
    )
}

private func drainCandidates(
    of composed: inout GraphComposedEncoder,
    sequence: ChoiceSequence
) -> [ChoiceSequence] {
    var candidates: [ChoiceSequence] = []
    var buffer = sequence
    while composed.nextProbe(into: &buffer, lastAccepted: false) != nil {
        candidates.append(buffer)
    }
    return candidates
}

/// Drains a three-stage composition over one leaf at 100 in `0...1000`. Each stage's downstream binary search starts from that stage's upstream value, so stages emit different probes; the stage is identified by the upstream value its wrapped mutation carries.
private func stageProbes(probesPerStageTurn: Int?) throws -> [(stage: UInt64, candidate: ChoiceSequence)] {
    let scope = try #require(singleLeafScope(value: 100))
    var composed = GraphComposedEncoder(
        name: .composed,
        upstream: .binarySearch(GraphBinarySearchEncoder()),
        upstreamScope: scope,
        upstreamBudget: 3,
        probesPerStageTurn: probesPerStageTurn,
        downstreamBuilder: { candidate, _, _ in
            guard let liftedValue = candidate.compactMap({ $0.value?.choice.bitPattern64 }).first,
                  let liftedScope = singleLeafScope(value: liftedValue)
            else {
                return nil
            }
            return (.binarySearch(GraphBinarySearchEncoder()), liftedScope)
        }
    )

    composed.start(scope: scope)
    var probes: [(stage: UInt64, candidate: ChoiceSequence)] = []
    var buffer = scope.baseSequence
    while let mutation = composed.nextProbe(into: &buffer, lastAccepted: false) {
        guard case let .leafValues(changes) = mutation, let change = changes.first else {
            Issue.record("Expected a leafValues mutation, got \(mutation)")
            return probes
        }
        probes.append((change.newValue.bitPattern64, buffer))
    }
    return probes
}

private func singleLeafScope(value: UInt64) -> EncoderInput? {
    let tree = ChoiceTree.group([
        .choice(ChoiceValue(value, tag: .uint64), .init(validRange: 0 ... 1000, isRangeExplicit: true)),
    ])
    return minimizationScope(
        tree: tree,
        graph: ChoiceGraph.build(from: tree),
        sequence: ChoiceSequence.flatten(tree)
    )
}

private func longestRun(of stages: [UInt64]) -> Int {
    var longest = 0
    var current = 0
    var previous: UInt64?
    for stage in stages {
        current = stage == previous ? current + 1 : 1
        longest = max(longest, current)
        previous = stage
    }
    return longest
}
