import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Numeric pair search")
struct NumericPairSearchTests {
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
            let leaf = ReductionLeaf(
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
                let jointCandidates = NumericPairCandidates.jointValues(for: leaf, simplifying: simplifying)
                return (tag.isFloatingPoint || jointCandidates == Self.uncappedJointValues(for: leaf, simplifying: simplifying))
                    && jointCandidates.count <= NumericPairCandidates.maximumJointSamples
                    && candidates.count <= NumericPairCandidates.maximumSamples
                    && [candidates, jointCandidates].allSatisfy { Set($0).count == $0.count }
                    && (candidates + jointCandidates).allSatisfy { pattern in
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
        #expect(StagedJointQuery.pairs(graph: graph, isFruitlessBind: gate.isFruitless, tuning: .init()).isEmpty)
        let source = try #require(graph.leafNodes.first)
        Self.markConverged(source, in: &graph)
        #expect(StagedJointQuery.pairs(graph: graph, isFruitlessBind: gate.isFruitless, tuning: .init()).count == 1)
        graph.convergenceStore[source] = ConvergedOrigin(
            bound: 4,
            signal: .monotoneConvergence,
            configuration: .binarySearchSemanticSimplest,
            cycle: 0
        )
        #expect(StagedJointQuery.pairs(graph: graph, isFruitlessBind: gate.isFruitless, tuning: .init()).isEmpty)
    }

    @Test("Exhausted pair scopes compare domains and all partners")
    func pairScopeEquality() throws {
        var graph = Self.graph(values: [3, 0, 0], range: 0 ... 20)
        try Self.markConverged(#require(graph.leafNodes.first), in: &graph)
        let gate = BoundValueGate(baseBudget: 15)
        let pairs = StagedJointQuery.pairs(graph: graph, isFruitlessBind: gate.isFruitless, tuning: .init())
        #expect(pairs.count == 2)
        #expect(StagedJointQuery.pairs(graph: graph, isFruitlessBind: gate.isFruitless, tuning: .init()) == pairs)
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
        let pairs = StagedJointQuery.pairs(graph: graph, isFruitlessBind: BoundValueGate(baseBudget: 15).isFruitless, tuning: .init())
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
        #expect(StagedJointQuery.pairs(graph: graph, isFruitlessBind: gate.isFruitless, tuning: .init()).isEmpty)
        graph.bindClassifications[42] = BindClassification(topology: .identical, liftability: .both)
        #expect(StagedJointQuery.pairs(graph: graph, isFruitlessBind: gate.isFruitless, tuning: .init()).count == 1)
        graph.bindClassifications[42] = BindClassification(topology: .divergent, liftability: .both)
        #expect(StagedJointQuery.pairs(graph: graph, isFruitlessBind: gate.isFruitless, tuning: .init()).isEmpty)
        graph.bindClassifications[42] = BindClassification(topology: .identical, liftability: .lowOnly)
        #expect(StagedJointQuery.pairs(graph: graph, isFruitlessBind: gate.isFruitless, tuning: .init()).isEmpty)
    }

    @Test("Numeric leaves behind more non-numeric leaves than the leaf cap are still paired")
    func numericLeavesBeyondTheCap() throws {
        let character = ChoiceTree.choice(
            ChoiceValue(UInt64(97), tag: .character),
            .init(validRange: 0 ... 0x10FFFF, isRangeExplicit: true)
        )
        let characterCount = ReductionTuning().numericPairMaximumLeaves + 44
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
        let pairs = StagedJointQuery.pairs(graph: graph, isFruitlessBind: BoundValueGate(baseBudget: 15).isFruitless, tuning: .init())
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
        let pair = try #require(StagedJointQuery.pairs(graph: graph, isFruitlessBind: BoundValueGate(baseBudget: 15).isFruitless, tuning: .init()).first)
        let admission = DecoderAdmission.numericPair(pair)

        #expect(admission.admits(tree: .bind(fingerprint: 42, inner: source, bound: sink)))
        #expect(admission.admits(tree: .bind(fingerprint: 43, inner: source, bound: sink)) == false)
    }

    @Test("Large integer neighbors remain exact without overflowing")
    func fullWidthIntegers() throws {
        var graph = Self.graph(values: [7, UInt64.max - 2], range: 0 ... UInt64.max)
        let source = try #require(graph.leafNodes.first)
        Self.markConverged(source, in: &graph)
        let pair = try #require(StagedJointQuery.pairs(graph: graph, isFruitlessBind: BoundValueGate(baseBudget: 15).isFruitless, tuning: .init()).first)
        let values = NumericPairCandidates.values(for: pair.sink, simplifying: false)
        #expect(values.contains(UInt64.max - 1))
        #expect(values.contains(UInt64.max))
        #expect(values.contains(UInt64.max - 3))
        #expect(values.count <= NumericPairCandidates.maximumSamples)
        #expect(Set(values).count == values.count)
    }

    /// Reconstructs the original proposal stream, applying the six-value cap only after admission and deduplication.
    private static func uncappedJointValues(for leaf: ReductionLeaf, simplifying: Bool) -> [UInt64] {
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
