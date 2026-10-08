import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Reducer encoder eligibility")
struct EncoderEligibilityTests {
    @Test("Empty filters emit no probes even with picks inside binds", arguments: [false, true])
    func emptyFiltersEmitNoProbes(bound: Bool) throws {
        let fixture = try laterArmFixture(bound: bound)
        var machine = ReductionMachine(
            gen: fixture.generator,
            initialTree: fixture.tree,
            initialOutput: fixture.value,
            config: .init(maxStalls: 2, enabledEncoders: []),
            collectStats: true,
            property: { _ in
                Issue.record("An empty encoder filter must not invoke the property")
                return false
            }
        )
        let baseline = machine.sequence
        #expect(machine.graph.liveNodeIDs.contains { nodeID in
            if case .pick = machine.graph.nodes[nodeID].kind {
                return true
            }
            return false
        })
        if bound {
            #expect(machine.graph.liveNodeIDs.contains { nodeID in
                if case .bind = machine.graph.nodes[nodeID].kind {
                    return true
                }
                return false
            })
        }
        try finish(&machine)
        #expect(machine.sequence == baseline)
        #expect(machine.output as? UInt64 == fixture.value)
        #expect(machine.stats.reductionProbes == 0)
        #expect(machine.stats.relaxImprovingProbes == 0)
        #expect(machine.stats.encoderCounts.isEmpty)
        #expect(machine.stats.materializationsBySite[.classification] == nil)
        #expect(machine.stats.materializationsBySite[.rematerialization] == nil)
    }

    @Test("Value-only pick and bind runs stay in the selected arm", arguments: [false, true])
    func valueOnlyRunsStayInArm(bound: Bool) throws {
        let fixture = try laterArmFixture(bound: bound)
        var propertyCalls = 0
        var machine = ReductionMachine(
            gen: fixture.generator,
            initialTree: fixture.tree,
            initialOutput: fixture.value,
            config: .init(maxStalls: 2, enabledEncoders: [.valueSearch]),
            collectStats: true,
            property: { value in
                propertyCalls += 1
                #expect(value >= 200, "A value-only run must not probe the earlier arm")
                return value < 230
            }
        )
        try finish(&machine)
        #expect(propertyCalls > 0)
        let output = try #require(machine.output as? UInt64)
        #expect(output >= 230)
        #expect(output <= fixture.value)
        #expect(machine.stats.relaxImprovingProbes == 0)
        #expect(Set(machine.stats.encoderCounts.keys) == [.valueSearch])
    }

    @Test("Disabled post-cycle probes are removed before scheduling or rematerialization")
    func disabledActionsAreNotScheduled() throws {
        var machine = try reflectedMachine(generator: twoArms, value: UInt64(250), enabledEncoders: [.valueSearch]) { _ in
            Issue.record("Cycle evaluation must not invoke the property")
            return false
        }
        markConverged(&machine.graph)
        machine.graphIsStripped = true
        machine.hadUnresolvedReplacement = true
        machine.convergence.deferBindInner = false
        machine.convergence.stallBudget = 1
        machine.phase = .endCycle
        let rebuilds = machine.stats.graphStats.fullGraphRebuilds
        #expect(machine.hasUnprobedImprovingPivot == false)
        _ = machine.next()
        guard case .checkTermination = machine.phase else {
            Issue.record("Disabled probe actions must not enter the post-cycle queue")
            return
        }
        #expect(machine.stats.graphStats.fullGraphRebuilds == rebuilds)
        #expect(machine.stats.materializationsBySite[.rematerialization] == nil)
    }

    @Test("Improving pivot eligibility applies when the pass is called directly", arguments: [
        Set<EncoderName>(), [.valueSearch], [.substitution], [.branchPivot],
    ])
    func improvingPivotEligibility(enabledEncoders: Set<EncoderName>) throws {
        let enabled = enabledEncoders.contains(.branchPivot)
        var propertyCalls = 0
        var machine = try reflectedMachine(generator: twoArms, value: UInt64(250), enabledEncoders: enabledEncoders) { value in
            propertyCalls += 1
            #expect(enabled)
            return value < 80
        }
        let baseline = machine.sequence
        #expect(machine.hasUnprobedImprovingPivot == enabled)
        let accepted = machine.runImprovingPivotPass()
        #expect(accepted == enabled)
        #expect(machine.sequence.shortLexPrecedes(baseline) == enabled)
        #expect(machine.stats.relaxImprovingAcceptances == (enabled ? 1 : 0))
        #expect((propertyCalls > 0) == enabled)
    }

    @Test("Disabled manual passes remain inert even when explicitly placed in the action queue")
    func disabledManualActionsAreInert() throws {
        var machine = try reflectedMachine(generator: twoArms, value: UInt64(250), enabledEncoders: []) { _ in
            Issue.record("Disabled manual actions must not emit a probe")
            return false
        }
        markConverged(&machine.graph)
        let baseline = machine.sequence
        machine.phase = .postCycle(remaining: [.confirmConvergence, .relationPass, .improvingPivots, .pairwiseNumericPass, .excursion])
        try finish(&machine)
        #expect(machine.sequence == baseline)
        #expect(machine.stats.reductionProbes == 0)
        #expect(machine.stats.encoderCounts.isEmpty)
        #expect(machine.passCounter == 0)
    }

    @Test("Branch-only dispatch reports the branch identity without enabling subtree substitutions")
    func branchOnlyDispatchUsesBranchIdentity() throws {
        var tuning = SchedulerTuning()
        tuning.relaxImprovingProbeBudget = 0
        tuning.relaxMaterializationBudget = 0
        var machine = try reflectedMachine(generator: twoArms, value: UInt64(250), enabledEncoders: [.branchPivot], tuning: tuning) { _ in false }
        try finish(&machine)
        #expect(machine.output as? UInt64 == 0)
        #expect((machine.stats.encoderCounts[.branchPivot]?.accepted ?? 0) > 0)
        #expect(Set(machine.stats.encoderCounts.keys) == [.branchPivot])
    }

    @Test("Substitution-only dispatch does not pivot a pick with no subtree donors")
    func substitutionOnlyDoesNotPivot() throws {
        var machine = try reflectedMachine(generator: twoArms, value: UInt64(250), enabledEncoders: [.substitution]) { _ in
            Issue.record("Subtree substitution must not enable a branch pivot")
            return false
        }
        let baseline = machine.sequence
        try finish(&machine)
        #expect(machine.sequence == baseline)
        #expect(machine.output as? UInt64 == 250)
        #expect(machine.stats.reductionProbes == 0)
        #expect(machine.hasUnprobedImprovingPivot == false)
    }

    @Test("Replacement dispatch and reporting agree on each scope's identity")
    func replacementIdentitiesAgree() {
        let tree = replacementTree()
        let graph = ChoiceGraph.build(from: tree)
        let sequence = ChoiceSequence(tree)
        let scopes = ReplacementQuery.build(graph: graph)
        var encountered: Set<EncoderName> = []
        for replacement in scopes {
            let expected: EncoderName = switch replacement {
                case .branchPivot:
                    .branchPivot
                case .selfSimilar, .descendantPromotion:
                    .substitution
            }
            let operation = GraphOperation.replace(replacement)
            var encoder = ChoiceGraphScheduler.selectEncoder(for: operation, gen: twoArms.erase())
            encoder.start(scope: EncoderInput(
                transformation: GraphTransformation(operation: operation, priority: .zeroBenefit),
                baseSequence: sequence,
                tree: tree,
                graph: graph,
                warmStartRecords: [:]
            ))
            #expect(operation.encoderName == expected)
            #expect(encoder.name == expected)
            encountered.insert(expected)
        }
        #expect(encountered == [.branchPivot, .substitution])
    }

    @Test("Excursion ranking excludes disabled replacements before applying the candidate limit", arguments: [EncoderName.branchPivot, .substitution], [0, 1, 3])
    func excursionRankingFiltersBeforeLimiting(name: EncoderName, limit: Int) {
        let tree = replacementTree()
        let graph = ChoiceGraph.build(from: tree)
        let sequence = ChoiceSequence(tree)
        let expected = eagerCandidates(sequence: sequence, graph: graph, name: name)
        var cursor = RelaxCandidateCursor(sequence: sequence, graph: graph, limit: limit, isEncoderEnabled: { $0 == name })
        var actual: [ChoiceSequence] = []
        while let candidate = cursor.next() {
            actual.append(candidate)
        }
        #expect(expected.isEmpty == false)
        #expect(cursor.candidateCount == expected.count)
        #expect(actual == Array(expected.prefix(limit)))
    }

    @Test("Excursion exploitation only runs enabled encoders", arguments: [false, true])
    func exploitationRespectsFilter(allowValueSearch: Bool) throws {
        let generator = Gen.arrayOf(twoArms, within: 2 ... 2)
        let enabled: Set<EncoderName> = allowValueSearch ? [.substitution, .valueSearch] : [.substitution]
        var tuning = SchedulerTuning()
        tuning.relaxMaterializationBudget = 1
        var propertyCalls = 0
        var machine = try reflectedMachine(generator: generator, value: [UInt64(10), 80], enabledEncoders: enabled, tuning: tuning) { _ in
            propertyCalls += 1
            return false
        }
        let baseline = machine.sequence
        let originalTree = machine.tree
        var candidates = RelaxCandidateCursor(sequence: baseline, graph: machine.graph, limit: 1, isEncoderEnabled: machine.isEncoderEnabled)
        let nextCandidate = candidates.next()
        let perturbation = try #require(nextCandidate)
        #expect(perturbation.shortLexPrecedes(baseline) == false, "The fixture must start with a worsening donor substitution")
        let committed = machine.runExcursion()
        #expect(committed == allowValueSearch)
        #expect(machine.sequence.shortLexPrecedes(baseline) == allowValueSearch)
        #expect(Set(machine.stats.encoderCounts.keys).isSubset(of: enabled))
        if allowValueSearch {
            #expect(propertyCalls > 1)
            #expect((machine.stats.encoderCounts[.valueSearch]?.emitted ?? 0) > 0)
        } else {
            #expect(propertyCalls == 1)
            #expect(machine.sequence == baseline)
            #expect(ChoiceSequence(machine.tree) == ChoiceSequence(originalTree))
            #expect(machine.output as? [UInt64] == [10, 80])
            #expect(machine.stats.encoderCounts[.valueSearch] == nil)
        }
    }

    @Test("Nil and explicitly enabling all encoders retain the same reduction behavior")
    func nilMatchesAllEncoders() throws {
        var unrestricted = try reflectedMachine(generator: twoArms, value: UInt64(250), enabledEncoders: nil) { $0 < 80 }
        var explicit = try reflectedMachine(generator: twoArms, value: UInt64(250), enabledEncoders: Set(EncoderName.allCases)) { $0 < 80 }
        try finish(&unrestricted)
        try finish(&explicit)
        #expect(unrestricted.sequence == explicit.sequence)
        #expect(unrestricted.output as? UInt64 == 80)
        #expect(explicit.output as? UInt64 == 80)
        #expect(unrestricted.stats.encoderCounts == explicit.stats.encoderCounts)
        #expect(unrestricted.stats.reductionProbes == explicit.stats.reductionProbes)
    }
}

// MARK: - Test Helpers

private let twoArms = Gen.pick(choices: [
    (1, Gen.choose(in: UInt64(0) ... 100)),
    (1, Gen.choose(in: UInt64(200) ... 300)),
])

/// Generates real bind trees rather than reflecting across a forward-only bind. The disjoint ranges identify the selected arm without depending on the random draw's exact value.
private func laterArmFixture(bound: Bool) throws -> (generator: Generator<UInt64>, value: UInt64, tree: ChoiceTree) {
    let generator = bound ? twoArms.wrapped(isReflective: true).bind { value in
        Gen.choose(in: value ... value + 100).wrapped(isReflective: true)
    }.gen : twoArms
    var iterator = ValueAndChoiceTreeInterpreter(generator, materializePicks: true, seed: 3, maxRuns: 100)
    while let (value, tree) = try iterator.next() {
        if value >= 230 {
            return (generator, value, tree)
        }
    }
    throw GeneratorError.choiceTreeConstructionFailed
}

/// Gives each decoder the same generator that produced the initial tree, keeping filter assertions independent of reconstruction failures.
private func reflectedMachine<Output>(
    generator: Generator<Output>,
    value: Output,
    enabledEncoders: Set<EncoderName>?,
    tuning: SchedulerTuning = .init(),
    property: @escaping (Output) -> Bool
) throws -> ReductionMachine {
    let tree = try #require(try Interpreters.reflect(generator, with: value))
    return ReductionMachine(
        gen: generator,
        initialTree: tree,
        initialOutput: value,
        config: .init(maxStalls: 2, enabledEncoders: enabledEncoders, tuning: tuning),
        collectStats: true,
        property: property
    )
}

/// Bounds the fixture's state-machine work without relying on a wall-clock timeout.
private func finish(_ machine: inout ReductionMachine) throws {
    for _ in 0 ..< 10000 {
        guard machine.next() != nil else {
            return
        }
    }
    Issue.record("The encoder eligibility fixture did not terminate")
}

private func markConverged(_ graph: inout ChoiceGraph) {
    for nodeID in graph.leafNodes {
        guard case let .chooseBits(metadata) = graph.nodes[nodeID].kind else {
            continue
        }
        graph.convergenceStore[nodeID] = ConvergedOrigin(bound: metadata.value.bitPattern64, signal: .monotoneConvergence, configuration: .binarySearchSemanticSimplest, cycle: 0)
    }
}

/// Includes shorter pivots and differently sized subtree donors, so filtering after ranking would change the budgeted prefix.
private func replacementTree() -> ChoiceTree {
    .group([
        .pickSite(fingerprint: 42, selected: 1, branches: [.uint64(0), .uint64(90)]),
        .pickSite(fingerprint: 42, selected: 1, branches: [.uint64(0), .uint64Zip([10, 20])]),
        .pickSite(fingerprint: 42, selected: 1, branches: [.uint64(0), .uint64(30)]),
    ])
}

/// Materializes every eligible splice before sorting, independently checking the bounded cursor's filtering and stable prefix.
private func eagerCandidates(sequence: ChoiceSequence, graph: ChoiceGraph, name: EncoderName) -> [ChoiceSequence] {
    var candidates: [ChoiceSequence] = []
    for scope in ReplacementQuery.build(graph: graph) where GraphOperation.replace(scope).encoderName == name {
        switch scope {
            case let .branchPivot(pickNodeID, targetBranchID):
                if let candidate = GraphStructuralEncoder.branchPivotCandidate(pickNodeID: pickNodeID, targetBranchID: targetBranchID, sequence: sequence, graph: graph) {
                    candidates.append(candidate)
                }
            case let .selfSimilar(targetNodeID, donorNodeID, _),
                 let .descendantPromotion(targetNodeID, donorNodeID, _):
                guard let targetRange = graph.nodes[targetNodeID].positionRange,
                      let donorRange = graph.nodes[donorNodeID].positionRange
                else {
                    continue
                }
                let replacement = GraphStructuralEncoder.expandDepthZeroLeaves(Array(sequence[donorRange]), donorNodeID: donorNodeID, donorRangeStart: donorRange.lowerBound, graph: graph)
                var candidate = sequence
                candidate.replaceSubrange(targetRange, with: replacement)
                if candidate != sequence {
                    candidates.append(candidate)
                }
        }
    }
    return candidates.sorted { $0.count < $1.count }
}
