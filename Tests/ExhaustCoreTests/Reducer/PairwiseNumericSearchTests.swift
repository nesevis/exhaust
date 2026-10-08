import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Pairwise numeric search")
struct PairwiseNumericSearchTests {
    @Test("Numeric candidates satisfy their domain contract and preserve joint palette order", arguments: [
        TypeTag.int, .int8, .int16, .int32, .int64,
        .uint, .uint8, .uint16, .uint32, .uint64, .float16, .float, .double,
    ])
    func candidateContract(tag: TypeTag) throws {
        let patterns = Gen.zip(
            Gen.choose() as Generator<UInt64>,
            Gen.zip(Gen.choose() as Generator<UInt64>, Gen.choose() as Generator<UInt64>)
        )
        try exhaustCheck(patterns, maxIterations: 500) { sample in
            let maximum = tag.bitPatternRange.upperBound
            let first = sample.0 & maximum
            let second = sample.1.0 & maximum
            let lower = min(first, second)
            let upper = max(first, second)
            let width = upper - lower
            let offset = width == UInt64.max ? sample.1.1 : sample.1.1 % (width + 1)
            let choice = ChoiceValue(lower + offset, tag: tag)
            let leaf = NumericPairQuery.Leaf(
                nodeID: 0,
                position: 0,
                path: [],
                choice: choice,
                range: lower ... upper,
                bindFingerprints: [],
                mayReshapeOnAcceptance: false
            )
            // The admission check compares whole sequences, so a simplifying candidate must make the sequence it is written into shortlex-smaller.
            let base = ChoiceSequence(.choice(choice, .init(validRange: lower ... upper, isRangeExplicit: true)))
            return [false, true].allSatisfy { simplifying in
                let candidates = NumericPairCandidates.values(for: leaf, simplifying: simplifying)
                return NumericPairCandidates.jointValues(for: leaf, simplifying: simplifying) == Self.uncappedJointValues(for: leaf, simplifying: simplifying)
                    && candidates.count <= NumericPairCandidates.maximumSamples
                    && Set(candidates).count == candidates.count
                    && candidates.allSatisfy { pattern in
                        let value = ChoiceValue(pattern, tag: tag)
                        var proposed = base
                        proposed[0] = proposed[0].withBitPattern(pattern)
                        return leaf.range.contains(pattern) && pattern != choice.bitPattern64
                            && (tag.isFloatingPoint == false || value.decodedDoubleValue.isFinite)
                            && (simplifying == false || proposed.shortLexPrecedes(base))
                    }
            }
        }
    }

    @Test("Only a current stalled source qualifies; an at-target partner needs no record")
    func sourceEligibility() throws {
        var graph = Self.graph(values: [3, 0], range: 0 ... 20)
        let gate = BoundValueGate(baseBudget: 15)
        #expect(NumericPairQuery.build(graph: graph, gate: gate).isEmpty)
        let source = try #require(graph.leafNodes.first)
        Self.markConverged(source, in: &graph)
        #expect(NumericPairQuery.build(graph: graph, gate: gate).count == 1)
        graph.convergenceStore[source] = ConvergedOrigin(
            bound: 4,
            signal: .monotoneConvergence,
            configuration: .binarySearchSemanticSimplest,
            cycle: 0
        )
        #expect(NumericPairQuery.build(graph: graph, gate: gate).isEmpty)
    }

    @Test("Exhausted pair scopes compare domains and all partners")
    func pairScopeEquality() throws {
        var graph = Self.graph(values: [3, 0, 0], range: 0 ... 20)
        try Self.markConverged(#require(graph.leafNodes.first), in: &graph)
        let gate = BoundValueGate(baseBudget: 15)
        let pairs = NumericPairQuery.build(graph: graph, gate: gate)
        #expect(pairs.count == 2)
        #expect(NumericPairQuery.build(graph: graph, gate: gate) == pairs)
        #expect(pairs != Array(pairs.prefix(1)))
        var stale = pairs
        let sink = stale[1].sink
        stale[1] = .init(source: stale[1].source, sink: .init(
            nodeID: sink.nodeID,
            position: sink.position,
            path: sink.path,
            choice: sink.choice,
            range: 0 ... 19,
            bindFingerprints: sink.bindFingerprints,
            mayReshapeOnAcceptance: sink.mayReshapeOnAcceptance
        ))
        #expect(pairs != stale)
    }

    @Test("Small integer domains cover every improving atomic pair without duplicates")
    func completeSmallDomain() throws {
        var graph = Self.graph(values: [7, 0], range: 0 ... 20)
        let source = try #require(graph.leafNodes.first)
        Self.markConverged(source, in: &graph)
        let pairs = NumericPairQuery.build(graph: graph, gate: BoundValueGate(baseBudget: 15))
        var cursor = NumericPairSearchCursor(pairs: pairs)
        let base = ChoiceSequence(Self.tree(values: [7, 0], range: 0 ... 20))
        var candidate = base
        var observed: Set<UInt64> = []
        var count = 0
        while cursor.next(into: &candidate) != nil {
            let values = candidate.compactMap { $0.value?.choice.bitPattern64 }
            #expect(values[0] < 7)
            #expect(values[1] > 0 && values[1] <= 20)
            #expect(candidate.shortLexPrecedes(base))
            #expect(observed.insert(values[0] * 21 + values[1]).inserted)
            count += 1
            candidate = base
        }
        #expect(count == 7 * 20)
    }

    @Test("Non-numeric tags and Boolean encodings are excluded")
    func excludesNonNumeric() {
        for tag: TypeTag in [.date, .character, .bits, .depthControl, .laneControl, .uint8] {
            let metadata = ChooseBitsMetadata(
                typeTag: tag,
                validRange: 0 ... 1,
                isRangeExplicit: true,
                value: ChoiceValue(UInt64(1), tag: tag),
                typeTagPayload: nil
            )
            #expect(NumericPairQuery.isNumeric(metadata) == false)
        }
    }

    @Test("Relax scheduling solves weighted equalities beyond fixed exchange rates", arguments: [2, 3, 5, 7])
    func weightedEquality(weight: Int) throws {
        let integer = Gen.choose(in: 0 ... 50)
        let generator = Gen.zip(integer, integer, integer)
        let start = (2, 0, 50 - 2 * weight)
        let initialTree = try #require(try Interpreters.reflect(generator, with: start))
        var machine = ReductionMachine(
            gen: generator,
            initialTree: initialTree,
            initialOutput: start,
            config: .init(maxStalls: 3, enabledEncoders: Set(EncoderName.allCases).subtracting([.stagedJointSearch])),
            collectStats: true,
            property: { $0.0 * weight + $0.1 + $0.2 != 50 }
        )
        while machine.next() != nil {}
        let result = try #require(machine.output as? (Int, Int, Int))
        #expect(result.0 == 0 && result.1 == 0 && result.2 == 50)
        #expect((machine.stats.encoderCounts[.pairwiseNumericSearch]?.accepted ?? 0) > 0)
    }

    @Test("A failed phase spends its budget once for the same base")
    func budgetAndExhaustion() throws {
        let generator = Gen.zip(Gen.choose(in: 0 ... 20), Gen.choose(in: 0 ... 20))
        let start = (3, 0)
        let initialTree = try #require(try Interpreters.reflect(generator, with: start))
        var machine = ReductionMachine(
            gen: generator,
            initialTree: initialTree,
            initialOutput: start,
            config: .init(maxStalls: 3, enabledEncoders: Set(EncoderName.allCases).subtracting([.stagedJointSearch]), tuning: .init(pairwiseNumericProbeBudget: 7)),
            collectStats: true,
            property: { $0 != start }
        )
        machine.convergence.deferBindInner = false
        let source = try #require(machine.graph.leafNodes.first)
        Self.markConverged(source, in: &machine.graph)
        #expect(try machine.runPairwiseNumericSearch() == false)
        let counts = try #require(machine.stats.encoderCounts[.pairwiseNumericSearch])
        #expect(counts.emitted == 7)
        #expect(counts.materializationAttempts == 7)
        #expect(machine.pendingNumericPairs() == nil)
        #expect(try machine.runPairwiseNumericSearch() == false)
        #expect(machine.stats.encoderCounts[.pairwiseNumericSearch] == counts)
    }

    @Test("Pair probes use the shared rejection cache before materialization")
    func cachedPairProbe() throws {
        let generator = Gen.zip(Gen.choose(in: 0 ... 20), Gen.choose(in: 0 ... 20))
        let start = (3, 0)
        let initialTree = try #require(try Interpreters.reflect(generator, with: start))
        var machine = ReductionMachine(
            gen: generator,
            initialTree: initialTree,
            initialOutput: start,
            config: .init(maxStalls: 3, enabledEncoders: Set(EncoderName.allCases).subtracting([.stagedJointSearch]), tuning: .init(pairwiseNumericProbeBudget: 1)),
            collectStats: true,
            property: { _ in
                Issue.record("Cached probes must not invoke the property")
                return true
            }
        )
        machine.convergence.deferBindInner = false
        try Self.markConverged(#require(machine.graph.leafNodes.first), in: &machine.graph)
        let pairs = try #require(machine.pendingNumericPairs())
        var cursor = NumericPairSearchCursor(pairs: pairs)
        var candidate = machine.sequence
        let firstPair = cursor.next(into: &candidate)
        _ = try #require(firstPair)
        machine.rejectCache.insert(ZobristHash.hash(of: candidate))
        #expect(try machine.runPairwiseNumericSearch() == false)
        let counts = try #require(machine.stats.encoderCounts[.pairwiseNumericSearch])
        #expect(counts.emitted == 1)
        #expect(counts.rejectedByCache == 1)
        #expect(counts.materializationAttempts == 0)
    }

    @Test("Signed and finite floating pairs use numeric values across scales", arguments: [0.5, 3.0, 1024.0])
    func floatingPairs(scale: Double) throws {
        let generator = Gen.zip(Gen.choose(in: 0.0 ... (4 * scale)), Gen.choose(in: 0.0 ... (8 * scale)))
        let start = (2 * scale, 0.0)
        let initialTree = try #require(try Interpreters.reflect(generator, with: start))
        var machine = ReductionMachine(
            gen: generator,
            initialTree: initialTree,
            initialOutput: start,
            config: .init(maxStalls: 3, enabledEncoders: Set(EncoderName.allCases).subtracting([.stagedJointSearch])),
            collectStats: true,
            property: { $0.0 * 4 + $0.1 != 8 * scale }
        )
        machine.convergence.deferBindInner = false
        let source = try #require(machine.graph.leafNodes.first)
        Self.markConverged(source, in: &machine.graph)
        let accepted = machine.runPairwiseNumericSearch()
        #expect(accepted)
        let result = try #require(machine.output as? (Double, Double))
        #expect(result.0 == 0 && result.1 == 8 * scale)
        let counts = try #require(machine.stats.encoderCounts[.pairwiseNumericSearch])
        #expect(counts.materializationAttempts == counts.emitted + 1)
    }

    @Test("Negative sources compensate using a different integer type")
    func mixedSignedPair() throws {
        let generator = Gen.zip(Gen.choose(in: Int8(-5) ... 0), Gen.choose(in: UInt64(0) ... 20))
        let start = (Int8(-3), UInt64(0))
        let initialTree = try #require(try Interpreters.reflect(generator, with: start))
        var machine = ReductionMachine(
            gen: generator,
            initialTree: initialTree,
            initialOutput: start,
            config: .init(maxStalls: 3, enabledEncoders: Set(EncoderName.allCases).subtracting([.stagedJointSearch])),
            collectStats: true,
            property: { Int($0.0) * -3 + Int($0.1) != 9 }
        )
        machine.convergence.deferBindInner = false
        let source = try #require(machine.graph.leafNodes.first)
        Self.markConverged(source, in: &machine.graph)
        let accepted = machine.runPairwiseNumericSearch()
        #expect(accepted)
        let result = try #require(machine.output as? (Int8, UInt64))
        #expect(Int(result.0) * -3 + Int(result.1) == 9)
        #expect(result.0 > start.0)
    }

    @Test("Forward-only binds preserve the compensating edit with fresh bounds")
    func forwardOnlyBind() throws {
        let generator = Gen.choose(in: 0 ... 5).wrapped(isReflective: true).bind { source in
            Gen.choose(in: 0 ... (2 * source)).wrapped(isReflective: true).map { (source, $0) }
        }
        let start = (4, 2)
        let initialTree = try Self.recordedTree(generator.gen, matching: start)
        var machine = ReductionMachine(
            gen: generator.gen,
            initialTree: initialTree,
            initialOutput: start,
            config: .init(maxStalls: 3, enabledEncoders: Set(EncoderName.allCases).subtracting([.stagedJointSearch])),
            collectStats: true,
            property: { $0.0 * 2 + $0.1 != 10 }
        )
        machine.convergence.deferBindInner = false
        let source = try #require(machine.graph.leafNodes.first)
        let bindID = try #require(machine.graph.nodes[source].scopeAnnotation.controllingBindNodeID)
        guard case let .bind(metadata) = machine.graph.nodes[bindID].kind else {
            Issue.record("Expected controlling bind")
            return
        }
        machine.convergence.gate.recordOutcome(fingerprint: metadata.fingerprint, accepted: false)
        let fullBudget = SchedulerTuning().boundValueBaseBudget
        #expect(machine.convergence.gate.decayedBudget(fingerprint: metadata.fingerprint) < fullBudget)
        #expect(machine.graph.convergenceStore[source] == nil)
        let accepted = machine.runPairwiseNumericSearch()
        #expect(accepted)
        let result = try #require(machine.output as? (Int, Int))
        #expect(machine.convergence.gate.decayedBudget(fingerprint: metadata.fingerprint) == fullBudget)
        #expect(machine.convergence.gate.isFirstDispatch(fingerprint: metadata.fingerprint) == false)
        #expect(machine.graph.convergenceStore.isEmpty)
        #expect(ChoiceSequence(machine.tree) == machine.sequence)
        #expect(result.0 < 4 && result.1 > 2)
        #expect(result.1 <= 2 * result.0)
        #expect(result.0 * 2 + result.1 == 10)
        guard case let .success(replayed, _, _) = Materializer.materializeAny(
            generator.gen.erase(), context: .init(prefix: machine.sequence, mode: .exact)
        ) else {
            Issue.record("Accepted history must replay")
            return
        }
        let replayedPair = try #require(replayed as? (Int, Int))
        #expect(replayedPair == result)
    }

    @Test("A clamped compensating edit never reaches the property")
    func rejectsClampedSink() throws {
        let generator = Gen.choose(in: 0 ... 2).wrapped(isReflective: true).bind { source in
            Gen.choose(in: 0 ... source).wrapped(isReflective: true).map { (source, $0) }
        }
        let start = (2, 0)
        let initialTree = try Self.recordedTree(generator.gen, matching: start)
        var evaluations: [(Int, Int)] = []
        var machine = ReductionMachine(
            gen: generator.gen,
            initialTree: initialTree,
            initialOutput: start,
            config: .init(maxStalls: 3, enabledEncoders: Set(EncoderName.allCases).subtracting([.stagedJointSearch])),
            collectStats: true,
            property: { candidate in
                evaluations.append(candidate)
                return candidate != start
            }
        )
        machine.convergence.deferBindInner = false
        let source = try #require(machine.graph.leafNodes.first)
        Self.markConverged(source, in: &machine.graph)
        #expect(try machine.runPairwiseNumericSearch() == false)
        #expect(evaluations.allSatisfy { $0 == (1, 1) })
        #expect(evaluations.count == 1)
        #expect((machine.stats.encoderCounts[.pairwiseNumericSearch]?.rejectedDuringMaterialization ?? 0) > 0)
    }

    @Test("Pair probes mark only bind-inner edits as reshaping", arguments: [false, true])
    func reshapeFollowsBindInner(sourceIsBindInner: Bool) throws {
        let source = Self.tree(values: [3], range: 0 ... 20)
        let sink = Self.tree(values: [0], range: 0 ... 20)
        let tree: ChoiceTree = switch sourceIsBindInner {
            case true:
                .bind(fingerprint: 42, inner: source, bound: sink)
            case false:
                .group([source, sink])
        }
        var graph = ChoiceGraph.build(from: tree)
        graph.bindClassifications[42] = BindClassification(topology: .identical, liftability: .both)
        try Self.markConverged(#require(graph.leafNodes.first), in: &graph)
        let pairs = NumericPairQuery.build(graph: graph, gate: BoundValueGate(baseBudget: 15))
        let sequence = ChoiceSequence(tree)
        var encoder = NumericPairEncoder()
        encoder.start(scope: EncoderInput(
            transformation: GraphTransformation(
                operation: .exchange(.numericPairs(pairs, probeBudget: 4)),
                priority: DispatchPriority(
                    structuralBenefit: 0,
                    valueBenefit: 0,
                    reductionMagnitude: 0,
                    estimatedCost: 4
                )
            ),
            baseSequence: sequence,
            tree: tree,
            graph: graph,
            warmStartRecords: [:]
        ))
        var candidate = sequence
        guard case let .leafValues(changes) = encoder.nextProbe(into: &candidate, lastAccepted: false) else {
            Issue.record("Expected a leaf-value probe")
            return
        }
        #expect(changes.map { $0.mayReshape } == [sourceIsBindInner, false])
    }

    @Test("Cached topology determines whether a nonconstant bind is eligible")
    func bindClassificationEligibility() throws {
        let source = Self.tree(values: [3], range: 0 ... 20)
        let sink = ChoiceTree.group([
            .branch(fingerprint: 17, weight: 1, id: 0, branchCount: 1,
                    choice: Self.tree(values: [0], range: 0 ... 20), isSelected: true),
        ])
        var graph = ChoiceGraph.build(from: .bind(fingerprint: 42, inner: source, bound: sink))
        let sourceID = try #require(graph.leafNodes.first)
        Self.markConverged(sourceID, in: &graph)
        let gate = BoundValueGate(baseBudget: 15)
        #expect(NumericPairQuery.build(graph: graph, gate: gate).isEmpty)
        graph.bindClassifications[42] = BindClassification(topology: .identical, liftability: .both)
        #expect(NumericPairQuery.build(graph: graph, gate: gate).count == 1)
        graph.bindClassifications[42] = BindClassification(topology: .divergent, liftability: .both)
        #expect(NumericPairQuery.build(graph: graph, gate: gate).isEmpty)
        graph.bindClassifications[42] = BindClassification(topology: .identical, liftability: .lowOnly)
        #expect(NumericPairQuery.build(graph: graph, gate: gate).isEmpty)
    }

    @Test("Numeric leaves behind more non-numeric leaves than the leaf cap are still paired")
    func numericLeavesBeyondTheCap() throws {
        let character = ChoiceTree.choice(
            ChoiceValue(UInt64(97), tag: .character),
            .init(validRange: 0 ... 0x10FFFF, isRangeExplicit: true)
        )
        let characterCount = NumericPairQuery.maximumLeaves + 44
        let text = ChoiceTree.sequence(
            elements: Array(repeating: character, count: characterCount),
            metadata: .init(validRange: UInt64(characterCount) ... UInt64(characterCount), isRangeExplicit: true)
        )
        let numbers = Self.tree(values: [3, 0], range: 0 ... 20)
        var graph = ChoiceGraph.build(from: .group([text, numbers]))
        let source = try #require(graph.leafNodes.first { nodeID in
            guard case let .chooseBits(metadata) = graph.nodes[nodeID].kind else {
                return false
            }
            return metadata.typeTag == .uint64
        })
        Self.markConverged(source, in: &graph)
        let pairs = NumericPairQuery.build(graph: graph, gate: BoundValueGate(baseBudget: 15))
        #expect(pairs.count == 1)
        #expect(pairs.first?.source.nodeID == source)
    }

    @Test("Pair admission rejects a failure whose leaf lands under a different bind site")
    func admissionRejectsMovedBindSite() throws {
        let source = Self.tree(values: [3], range: 0 ... 20)
        let sink = Self.tree(values: [0], range: 0 ... 20)
        var graph = ChoiceGraph.build(from: .bind(fingerprint: 42, inner: source, bound: sink))
        graph.bindClassifications[42] = BindClassification(topology: .identical, liftability: .both)
        try Self.markConverged(#require(graph.leafNodes.first), in: &graph)
        let pair = try #require(NumericPairQuery.build(graph: graph, gate: BoundValueGate(baseBudget: 15)).first)
        let admission = DecoderAdmission.numericPair(pair)

        #expect(admission.admits(tree: .bind(fingerprint: 42, inner: source, bound: sink)))
        #expect(admission.admits(tree: .bind(fingerprint: 43, inner: source, bound: sink)) == false)
    }

    @Test("Large integer neighbors remain exact without overflowing")
    func fullWidthIntegers() throws {
        var graph = Self.graph(values: [7, UInt64.max - 2], range: 0 ... UInt64.max)
        let source = try #require(graph.leafNodes.first)
        Self.markConverged(source, in: &graph)
        let pair = try #require(NumericPairQuery.build(graph: graph, gate: BoundValueGate(baseBudget: 15)).first)
        let values = NumericPairCandidates.values(for: pair.sink, simplifying: false)
        #expect(values.contains(UInt64.max - 1))
        #expect(values.contains(UInt64.max))
        #expect(values.contains(UInt64.max - 3))
        #expect(values.count <= NumericPairCandidates.maximumSamples)
        #expect(Set(values).count == values.count)
    }

    /// Captures a forward-only history without requiring an inverse for either closure.
    private static func recordedTree(_ generator: Generator<(Int, Int)>, matching start: (Int, Int)) throws -> ChoiceTree {
        var iterator = ValueAndChoiceTreeInterpreter(generator, seed: 1337, maxRuns: 2000)
        while let (value, tree) = try iterator.next() {
            if value == start {
                return tree
            }
        }
        throw RecordingFailure.missingStart
    }

    private enum RecordingFailure: Error {
        case missingStart
    }

    /// Reconstructs the original proposal stream, applying the six-value cap only after admission and deduplication.
    private static func uncappedJointValues(for leaf: NumericPairQuery.Leaf, simplifying: Bool) -> [UInt64] {
        let zero = leaf.choice.tag.simplestBitPattern
        let current = leaf.choice.bitPattern64
        let target = leaf.choice.reductionTarget(in: leaf.range)
        let half = current >= zero ? zero + (current - zero) / 2 : zero - (zero - current) / 2
        var proposals = [target, half, min(current, target) + (max(current, target) - min(current, target)) / 2]
        func appendMagnitude(_ magnitude: UInt64) {
            let (positive, overflow) = zero.addingReportingOverflow(magnitude)
            if overflow == false { proposals.append(positive) }
            if leaf.choice.tag.isSigned, zero >= magnitude { proposals.append(zero - magnitude) }
        }
        for magnitude: UInt64 in [1, 2, 3] {
            appendMagnitude(magnitude)
        }
        for delta: UInt64 in [1, 2, 4] {
            let (raised, overflow) = current.addingReportingOverflow(delta)
            if overflow == false { proposals.append(raised) }
            if current >= delta { proposals.append(current - delta) }
        }
        for exponent in 0 ..< 8 {
            appendMagnitude((UInt64(1) << exponent) - 1)
            appendMagnitude(UInt64(1) << exponent)
        }
        var visited: Set<UInt64> = []
        let admitted = proposals.filter { pattern in
            let value = ChoiceValue(pattern, tag: leaf.choice.tag)
            return pattern != current && leaf.range.contains(pattern) && visited.insert(pattern).inserted
                && (leaf.choice.tag.isFloatingPoint == false || value.decodedDoubleValue.isFinite)
                && (simplifying == false || value.shortlexKey < leaf.choice.shortlexKey
                    || (value.shortlexKey == leaf.choice.shortlexKey && pattern < current))
        }
        return Array(admitted.prefix(NumericPairCandidates.maximumJointSamples))
    }

    private static func markConverged(_ nodeID: Int, in graph: inout ChoiceGraph) {
        guard case let .chooseBits(metadata) = graph.nodes[nodeID].kind else {
            return
        }
        graph.convergenceStore[nodeID] = ConvergedOrigin(
            bound: metadata.value.bitPattern64,
            signal: .monotoneConvergence,
            configuration: .binarySearchSemanticSimplest,
            cycle: 0
        )
    }

    private static func tree(values: [UInt64], range: ClosedRange<UInt64>) -> ChoiceTree {
        .group(values.map { value in
            .choice(ChoiceValue(value, tag: .uint64), .init(validRange: range, isRangeExplicit: true))
        })
    }

    private static func graph(values: [UInt64], range: ClosedRange<UInt64>) -> ChoiceGraph {
        ChoiceGraph.build(from: tree(values: values, range: range))
    }
}
