import ExploreFixture
import Testing

@Suite("LengthGate reproducer smoke tests")
struct LengthGateSmokeTests {
    @Test("Fault L fires at 40 elements (registry minimal)")
    func faultLMinimal() {
        #expect(throws: LengthGateError.self) {
            _ = try LengthGate.process(LengthGateFixture.reproducerL)
        }
    }

    @Test("Fault L does not fire at 39 elements (strict prefix)")
    func faultLPrefixSafe() throws {
        let checksum = try LengthGate.process([Int](repeating: 1, count: 39))
        #expect(checksum == 39, "39 elements pass through and sum correctly")
    }

    @Test("Element values do not influence the gate")
    func valuesDoNotInfluenceGate() {
        #expect(throws: LengthGateError.self) {
            _ = try LengthGate.process([Int](repeating: 9, count: 48))
        }
    }
}

@Suite("DedupGate reproducer smoke tests")
struct DedupGateSmokeTests {
    @Test("Fault D2 fires on the ten-digit permutation (registry minimal)")
    func faultD2Minimal() {
        #expect(throws: DedupGateError.self) {
            _ = try DedupGate.ingest(DedupGateFixture.reproducerD2)
        }
    }

    @Test("Fault D2 does not fire on nine distinct elements (strict prefix)")
    func faultD2PrefixSafe() throws {
        let distinctCount = try DedupGate.ingest(Array(0 ... 8))
        #expect(distinctCount == 9, "nine distinct elements are below the count gate")
    }

    @Test("Fault D2 does not fire on ten elements with one duplicate")
    func faultD2DuplicateSafe() throws {
        let distinctCount = try DedupGate.ingest([0, 1, 2, 3, 4, 5, 6, 7, 8, 8])
        #expect(distinctCount == 9, "a single duplicate defeats the all-distinct requirement")
    }

    @Test("Eleven elements can never be all-distinct over the ten-digit domain")
    func faultD2PigeonholeSafe() throws {
        _ = try DedupGate.ingest([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0])
    }
}

@Suite("RecursiveDepth reproducer smoke tests")
struct RecursiveDepthSmokeTests {
    @Test("Fault RD fires on the depth-7 spine (registry minimal)")
    func faultRDMinimal() {
        #expect(throws: RecursiveDepthError.self) {
            _ = try RecursiveDepth.measure(RecursiveDepthFixture.reproducerRD)
        }
    }

    @Test("Fault RD does not fire at depth 6 (strict prefix)")
    func faultRDPrefixSafe() throws {
        var tree = SkewTree.tip
        for _ in 0 ..< 6 {
            tree = .node(left: tree, right: .tip, tag: 0)
        }
        let depth = try RecursiveDepth.measure(tree)
        #expect(depth == 6)
    }

    @Test("Depth follows the deeper child, not the node count")
    func depthFollowsDeeperChild() throws {
        // A bushy depth-2 tree with 7 nodes stays far under the gate.
        let leafPair = SkewTree.node(left: .tip, right: .tip, tag: 1)
        let bushy = SkewTree.node(left: leafPair, right: leafPair, tag: 2)
        let depth = try RecursiveDepth.measure(bushy)
        #expect(depth == 2, "node count does not determine depth on binary trees")
    }
}

@Suite("WideAligner reproducer smoke tests")
struct WideAlignerSmokeTests {
    @Test("Fault R2 fires on the aligned pair (registry minimal)")
    func faultR2Minimal() {
        #expect(throws: WideAlignError.self) {
            try WideAligner.check(WideAlignFixture.reproducerR2)
        }
    }

    @Test("Fault R2 does not fire with one alpha misaligned")
    func faultR2AlphaMismatchSafe() throws {
        try WideAligner.check(AlignedPair(alphas: [7, 7, 6], betas: [2, 2, 2]))
    }

    @Test("Fault R2 does not fire with one beta misaligned")
    func faultR2BetaMismatchSafe() throws {
        try WideAligner.check(AlignedPair(alphas: [7, 7, 7], betas: [2, 2, 3]))
    }

    @Test("Fault R2 does not fire when one side aligns alone")
    func faultR2SingleSiteSafe() throws {
        try WideAligner.check(AlignedPair(alphas: [7, 7, 7, 7, 7, 7], betas: [2, 2, 2, 2, 2, 1]))
    }

    @Test("Fault R2 requires both length floors")
    func faultR2LengthFloor() throws {
        try WideAligner.check(AlignedPair(alphas: [7, 7], betas: [2, 2, 2]))
    }

    @Test("Fault R2 fires at the longest aligned runs too")
    func faultR2LongRuns() {
        #expect(throws: WideAlignError.self) {
            try WideAligner.check(AlignedPair(
                alphas: [Int](repeating: 7, count: 6),
                betas: [Int](repeating: 2, count: 6)
            ))
        }
    }
}
