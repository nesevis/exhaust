@testable import ExhaustCore
import Testing

@Suite("ProductSpaceEncoder")
struct ProductSpaceEncoderTests {

    // MARK: - BinarySearchLadder

    @Test("BinarySearchLadder: midpoints computed correctly")
    func ladderMidpoints() {
        let ladder = BinarySearchLadder.compute(current: 100, target: 0, maxSteps: 6)
        #expect(ladder.values == [100, 50, 25, 12, 6, 3, 1, 0])
    }

    @Test("BinarySearchLadder: already at target")
    func ladderAlreadyAtTarget() {
        let ladder = BinarySearchLadder.compute(current: 0, target: 0)
        #expect(ladder.values == [0])
    }

    @Test("BinarySearchLadder: single step")
    func ladderSingleStep() {
        let ladder = BinarySearchLadder.compute(current: 1, target: 0)
        #expect(ladder.values == [1, 0])
    }

    @Test("BinarySearchLadder: current equals target (non-zero)")
    func ladderCurrentEqualsTarget() {
        let ladder = BinarySearchLadder.compute(current: 42, target: 42)
        #expect(ladder.values == [42])
    }

    @Test("BinarySearchLadder: current below target returns single value")
    func ladderCurrentBelowTarget() {
        let ladder = BinarySearchLadder.compute(current: 5, target: 10)
        #expect(ladder.values == [5])
    }

    // MARK: - ProductSpaceBatchEncoder: Single Bind (k=1)

    @Test("Single bind (k=1): produces ladder candidates")
    func singleBindLadder() {
        let inner = ChoiceTree.choice(
            .unsigned(100, .uint64),
            .init(validRange: 0 ... 200, isRangeExplicit: true)
        )
        let bound = ChoiceTree.choice(
            .unsigned(7, .uint64),
            .init(validRange: 0 ... 200, isRangeExplicit: true)
        )
        let tree = ChoiceTree.bind(inner: inner, bound: bound)
        let sequence = ChoiceSequence(tree)
        let bindIndex = BindSpanIndex(from: sequence)

        var encoder = ProductSpaceBatchEncoder()
        encoder.bindIndex = bindIndex
        encoder.dag = DependencyDAG.build(from: sequence, tree: tree, bindIndex: bindIndex)

        let candidates = Array(encoder.encode(sequence: sequence, targets: .wholeSequence))
        // Should produce candidates for the inner value (100 -> 0).
        #expect(candidates.isEmpty == false)

        // All candidates should differ from the original in the inner position.
        let innerIdx = bindIndex.regions[0].innerRange.lowerBound
        for candidate in candidates {
            let originalValue = sequence[innerIdx].value!.choice.bitPattern64
            let candidateValue = candidate[innerIdx].value!.choice.bitPattern64
            // At least some candidates should have different inner values.
            if candidateValue != originalValue {
                #expect(candidateValue < originalValue)
            }
        }

        // First candidate (shortlex-minimal) should have the smallest inner value.
        let firstCandidateInner = candidates[0][innerIdx].value!.choice.bitPattern64
        #expect(firstCandidateInner == 0)
    }

    // MARK: - ProductSpaceBatchEncoder: Two Independent Binds (k=2)

    @Test("Two independent binds (k=2): Cartesian product")
    func twoIndependentBinds() {
        let bind1 = ChoiceTree.bind(
            inner: .choice(.unsigned(10, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
            bound: .choice(.unsigned(2, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        )
        let bind2 = ChoiceTree.bind(
            inner: .choice(.unsigned(20, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
            bound: .choice(.unsigned(4, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        )
        let tree = ChoiceTree.group([bind1, bind2])
        let sequence = ChoiceSequence(tree)
        let bindIndex = BindSpanIndex(from: sequence)

        var encoder = ProductSpaceBatchEncoder()
        encoder.bindIndex = bindIndex
        encoder.dag = DependencyDAG.build(from: sequence, tree: tree, bindIndex: bindIndex)

        let candidates = Array(encoder.encode(sequence: sequence, targets: .wholeSequence))

        // Two axes: ladder1 for 10->0, ladder2 for 20->0.
        let ladder1 = BinarySearchLadder.compute(current: 10, target: 0)
        let ladder2 = BinarySearchLadder.compute(current: 20, target: 0)
        let expectedCount = ladder1.values.count * ladder2.values.count - 1 // minus identity
        #expect(candidates.count == expectedCount)

        // Candidates should be sorted shortlex.
        for index in 0..<(candidates.count - 1) {
            #expect(candidates[index].shortLexPrecedes(candidates[index + 1]))
        }
    }

    // MARK: - ProductSpaceBatchEncoder: Two Nested Binds (k=2, dependent)

    @Test("Two nested binds (k=2, dependent): topological ordering")
    func twoNestedBinds() {
        let valA = ChoiceTree.choice(.unsigned(50, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        let valB = ChoiceTree.choice(.unsigned(30, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        let valC = ChoiceTree.choice(.unsigned(10, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        let innerBind = ChoiceTree.bind(inner: valB, bound: valC)
        let outerBind = ChoiceTree.bind(inner: valA, bound: innerBind)

        let sequence = ChoiceSequence(outerBind)
        let bindIndex = BindSpanIndex(from: sequence)
        let dag = DependencyDAG.build(from: sequence, tree: outerBind, bindIndex: bindIndex)

        // Verify DAG has an edge from outer to inner.
        let topology = dag.bindInnerTopology()
        #expect(topology.count == 2)
        // First in topological order should be the outer bind (region 0).
        #expect(topology[0].regionIndex == 0)

        var encoder = ProductSpaceBatchEncoder()
        encoder.bindIndex = bindIndex
        encoder.dag = dag

        let candidates = Array(encoder.encode(sequence: sequence, targets: .wholeSequence))
        #expect(candidates.isEmpty == false)

        // Candidates should be sorted shortlex.
        for index in 0..<(candidates.count - 1) {
            #expect(candidates[index].shortLexPrecedes(candidates[index + 1]))
        }
    }

    // MARK: - Joint Reduction

    @Test("Joint reduction required: batch finds it")
    func jointReductionRequired() throws {
        // Two independent bind generators. Property fails only when BOTH inner values are above 5.
        // Sequential reduction of either alone would make the property pass.
        let bind1 = ChoiceTree.bind(
            inner: .choice(.unsigned(20, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
            bound: .choice(.unsigned(1, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        )
        let bind2 = ChoiceTree.bind(
            inner: .choice(.unsigned(30, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
            bound: .choice(.unsigned(1, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        )
        let tree = ChoiceTree.group([bind1, bind2])
        let sequence = ChoiceSequence(tree)
        let bindIndex = BindSpanIndex(from: sequence)

        var encoder = ProductSpaceBatchEncoder()
        encoder.bindIndex = bindIndex
        encoder.dag = DependencyDAG.build(from: sequence, tree: tree, bindIndex: bindIndex)

        let candidates = Array(encoder.encode(sequence: sequence, targets: .wholeSequence))

        // There should be candidates where both inner values are reduced simultaneously.
        let inner1Idx = bindIndex.regions[0].innerRange.lowerBound
        let inner2Idx = bindIndex.regions[1].innerRange.lowerBound

        let jointCandidates = candidates.filter { candidate in
            let value1 = candidate[inner1Idx].value!.choice.bitPattern64
            let value2 = candidate[inner2Idx].value!.choice.bitPattern64
            return value1 < 20 && value2 < 30
        }
        #expect(jointCandidates.isEmpty == false)

        // The first shortlex candidate should have both at their targets (0, 0).
        let first = candidates[0]
        let firstVal1 = first[inner1Idx].value!.choice.bitPattern64
        let firstVal2 = first[inner2Idx].value!.choice.bitPattern64
        #expect(firstVal1 == 0)
        #expect(firstVal2 == 0)
    }

    // MARK: - ProductSpaceAdaptiveEncoder: k=4

    @Test("k=4: adaptive mode initializes with four coordinates")
    func adaptiveFourCoordinates() {
        let binds = (0..<4).map { index in
            ChoiceTree.bind(
                inner: .choice(.unsigned(UInt64(10 + index * 10), .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
                bound: .choice(.unsigned(1, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
            )
        }
        let tree = ChoiceTree.group(binds)
        let sequence = ChoiceSequence(tree)
        let bindIndex = BindSpanIndex(from: sequence)

        var encoder = ProductSpaceAdaptiveEncoder()
        encoder.bindIndex = bindIndex
        encoder.start(sequence: sequence, targets: .wholeSequence)

        // First probe should halve all four coordinates.
        let probe = encoder.nextProbe(lastAccepted: false)
        #expect(probe != nil)

        // Each inner value should be halved.
        for (regionIndex, region) in bindIndex.regions.enumerated() {
            let innerIdx = region.innerRange.lowerBound
            let originalValue = UInt64(10 + regionIndex * 10)
            let probeValue = probe![innerIdx].value!.choice.bitPattern64
            #expect(probeValue < originalValue)
        }
    }

    // MARK: - Delta-Debug: Partial Halving

    @Test("Delta-debug: partial halving on rejection")
    func deltaDebugPartialHalving() {
        let binds = (0..<4).map { index in
            ChoiceTree.bind(
                inner: .choice(.unsigned(UInt64(100 + index * 100), .uint64), .init(validRange: 0 ... 1000, isRangeExplicit: true)),
                bound: .choice(.unsigned(1, .uint64), .init(validRange: 0 ... 1000, isRangeExplicit: true))
            )
        }
        let tree = ChoiceTree.group(binds)
        let sequence = ChoiceSequence(tree)
        let bindIndex = BindSpanIndex(from: sequence)

        var encoder = ProductSpaceAdaptiveEncoder()
        encoder.bindIndex = bindIndex
        encoder.start(sequence: sequence, targets: .wholeSequence)

        // First probe: halve all four.
        let firstProbe = encoder.nextProbe(lastAccepted: false)
        #expect(firstProbe != nil)

        // Reject the first probe — should enter delta-debug and try a partition.
        let secondProbe = encoder.nextProbe(lastAccepted: false)
        #expect(secondProbe != nil)

        // The second probe should modify only a subset of coordinates.
        var changedCount = 0
        for region in bindIndex.regions {
            let innerIdx = region.innerRange.lowerBound
            let original = sequence[innerIdx].value!.choice.bitPattern64
            let probeVal = secondProbe![innerIdx].value!.choice.bitPattern64
            if probeVal != original {
                changedCount += 1
            }
        }
        #expect(changedCount < 4)
        #expect(changedCount > 0)
    }

    // MARK: - Cost Estimate

    @Test("Estimated cost for k=3 is at most 512")
    func costEstimateK3() {
        let binds = (0..<3).map { index in
            ChoiceTree.bind(
                inner: .choice(.unsigned(UInt64(10 + index * 10), .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
                bound: .choice(.unsigned(1, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
            )
        }
        let tree = ChoiceTree.group(binds)
        let sequence = ChoiceSequence(tree)
        let bindIndex = BindSpanIndex(from: sequence)

        let encoder = ProductSpaceBatchEncoder()
        let cost = encoder.estimatedCost(sequence: sequence, bindIndex: bindIndex)
        #expect(cost != nil)
        #expect(cost! <= 512)
    }

    // MARK: - DependencyDAG.bindInnerTopology

    @Test("bindInnerTopology: independent binds have no dependencies")
    func topologyIndependent() {
        let bind1 = ChoiceTree.bind(
            inner: .choice(.unsigned(1, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
            bound: .choice(.unsigned(2, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true))
        )
        let bind2 = ChoiceTree.bind(
            inner: .choice(.unsigned(3, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
            bound: .choice(.unsigned(4, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true))
        )
        let tree = ChoiceTree.group([bind1, bind2])
        let sequence = ChoiceSequence(tree)
        let bindIndex = BindSpanIndex(from: sequence)
        let dag = DependencyDAG.build(from: sequence, tree: tree, bindIndex: bindIndex)

        let topology = dag.bindInnerTopology()
        #expect(topology.count == 2)
        for entry in topology {
            #expect(entry.dependsOn.isEmpty)
        }
    }

    @Test("bindInnerTopology: nested binds have dependency edge")
    func topologyNested() {
        let valA = ChoiceTree.choice(.unsigned(10, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        let valB = ChoiceTree.choice(.unsigned(20, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        let valC = ChoiceTree.choice(.unsigned(30, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        let innerBind = ChoiceTree.bind(inner: valB, bound: valC)
        let outerBind = ChoiceTree.bind(inner: valA, bound: innerBind)

        let sequence = ChoiceSequence(outerBind)
        let bindIndex = BindSpanIndex(from: sequence)
        let dag = DependencyDAG.build(from: sequence, tree: outerBind, bindIndex: bindIndex)

        let topology = dag.bindInnerTopology()
        #expect(topology.count == 2)

        // First in topological order: outer (region 0), depends on nothing among bind-inners.
        #expect(topology[0].regionIndex == 0)
        // Outer's dependsOn should contain the inner bind-inner node index.
        #expect(topology[0].dependsOn.isEmpty == false)

        // Second: inner (region 1), no outgoing bind-inner dependencies.
        #expect(topology[1].regionIndex == 1)
    }
}
