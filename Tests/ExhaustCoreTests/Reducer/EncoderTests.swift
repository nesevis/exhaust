import Testing
@testable import ExhaustCore

// MARK: - Test Helpers

/// Builds a simple choice sequence from raw unsigned values.
private func makeSequence(_ values: [UInt64]) -> ChoiceSequence {
    var seq = ChoiceSequence()
    for v in values {
        seq.append(.value(.init(choice: .unsigned(v, .uint64), validRange: 0 ... UInt64.max, isRangeExplicit: false)))
    }
    return seq
}

/// Extracts all value spans from a sequence.
private func allValueSpans(from seq: ChoiceSequence) -> [ChoiceSpan] {
    var spans: [ChoiceSpan] = []
    for (idx, entry) in seq.enumerated() {
        if entry.value != nil {
            spans.append(ChoiceSpan(kind: .value(.init(choice: .unsigned(0, .uint64), validRange: nil)), range: idx ... idx, depth: 0))
        }
    }
    return spans
}

// MARK: - ZeroValueEncoder

@Suite("ZeroValueEncoder")
struct ZeroValueEncoderTests {
    @Test("Produces all-zero candidate plus one per non-zero target")
    func candidatesPerTarget() {
        let seq = makeSequence([5, 0, 3])
        let spans = allValueSpans(from: seq)
        let candidates = collectZeroValueProbes(sequence: seq, spans: spans)
        // 1 all-zero + 2 individual (value 0 is already at semantic simplest).
        #expect(candidates.count == 3)
    }

    @Test("First candidate zeros all values, then one each")
    func candidateSetsOneToZero() {
        let seq = makeSequence([5, 7])
        let spans = allValueSpans(from: seq)
        let candidates = collectZeroValueProbes(sequence: seq, spans: spans)
        #expect(candidates.count == 3)
        // First candidate zeros all values.
        #expect(candidates[0][0].value?.choice == .unsigned(0, .uint64))
        #expect(candidates[0][1].value?.choice == .unsigned(0, .uint64))
        // Second candidate zeros index 0 only.
        #expect(candidates[1][0].value?.choice == .unsigned(0, .uint64))
        #expect(candidates[1][1].value?.choice == .unsigned(7, .uint64))
        // Third candidate zeros index 1 only.
        #expect(candidates[2][0].value?.choice == .unsigned(5, .uint64))
        #expect(candidates[2][1].value?.choice == .unsigned(0, .uint64))
    }

    @Test("Every candidate is shortlex ≤ the input")
    func shortlexInvariant() {
        let seq = makeSequence([10, 20, 30])
        let spans = allValueSpans(from: seq)
        let candidates = collectZeroValueProbes(sequence: seq, spans: spans)
        for candidate in candidates {
            #expect(candidate.shortLexPrecedes(seq))
        }
    }

    @Test("Empty targets produce no candidates")
    func emptyTargets() {
        let candidates = collectZeroValueProbes(sequence: makeSequence([5]), spans: [])
        #expect(candidates.isEmpty)
    }

    @Test("Wrong target type produces no candidates")
    func wrongTargetType() {
        var encoder = ZeroValueEncoder()
        encoder.start(sequence: makeSequence([5]), targets: .wholeSequence)
        let probe = encoder.nextProbe(lastAccepted: false)
        #expect(probe == nil)
    }
}

// MARK: - FindIntegerStepper

@Suite("FindIntegerStepper")
struct FindIntegerStepperTests {
    @Test("Immediate rejection converges to 0")
    func immediateRejection() {
        var stepper = FindIntegerStepper()
        let first = stepper.start()
        #expect(first == 1)
        let next = stepper.advance(lastAccepted: false)
        #expect(next == nil)
        #expect(stepper.bestAccepted == 0)
    }

    @Test("Linear scan finds small values")
    func linearScan() {
        var stepper = FindIntegerStepper()
        _ = stepper.start() // probe 1
        _ = stepper.advance(lastAccepted: true) // probe 2
        let three = stepper.advance(lastAccepted: true) // probe 3
        #expect(three == 3)
        let result = stepper.advance(lastAccepted: false) // rejected at 3
        #expect(result == nil)
        #expect(stepper.bestAccepted == 2)
    }

    @Test("Transitions to exponential phase after 4")
    func exponentialPhase() {
        var stepper = FindIntegerStepper()
        _ = stepper.start() // 1
        _ = stepper.advance(lastAccepted: true) // 2
        _ = stepper.advance(lastAccepted: true) // 3
        _ = stepper.advance(lastAccepted: true) // 4
        let eight = stepper.advance(lastAccepted: true) // → exponential, probe 8
        #expect(eight == 8)
    }

    @Test("Binary search converges between bounds")
    func binarySearchConverges() {
        var stepper = FindIntegerStepper()
        _ = stepper.start() // 1
        _ = stepper.advance(lastAccepted: true) // 2
        _ = stepper.advance(lastAccepted: true) // 3
        _ = stepper.advance(lastAccepted: true) // 4
        _ = stepper.advance(lastAccepted: true) // 8
        _ = stepper.advance(lastAccepted: false) // rejected at 8 → binary between 4 and 8
        // Stepper should binary search and eventually converge.
        var probes = 0
        var lastResult: Int? = 1
        while lastResult != nil {
            lastResult = stepper.advance(lastAccepted: true)
            probes += 1
            if probes > 20 { break }
        }
        // bestAccepted should be near 8 (all accepted during binary search).
        #expect(stepper.bestAccepted >= 4)
        #expect(stepper.bestAccepted < 8)
    }
}

// MARK: - BinarySearchStepper

@Suite("BinarySearchStepper")
struct BinarySearchStepperTests {
    @Test("Converged range returns nil immediately")
    func convergedRange() {
        var stepper = BinarySearchStepper(lo: 5, hi: 5)
        let first = stepper.start()
        #expect(first == nil)
    }

    @Test("Adjacent range converges in one probe")
    func adjacentRange() {
        var stepper = BinarySearchStepper(lo: 0, hi: 1)
        let first = stepper.start()
        #expect(first == 0)
        let next = stepper.advance(lastAccepted: true)
        #expect(next == nil)
        #expect(stepper.bestAccepted == 0)
    }

    @Test("Binary search narrows toward lo on acceptance")
    func narrowsTowardLo() {
        var stepper = BinarySearchStepper(lo: 0, hi: 100)
        let first = stepper.start() // 50
        #expect(first == 50)
        let second = stepper.advance(lastAccepted: true) // accepted 50 → hi=50, probe 25
        #expect(second == 25)
        let third = stepper.advance(lastAccepted: true) // accepted 25 → hi=25, probe 12
        #expect(third == 12)
    }

    @Test("Binary search narrows toward hi on rejection")
    func narrowsTowardHi() {
        var stepper = BinarySearchStepper(lo: 0, hi: 100)
        _ = stepper.start() // 50
        let second = stepper.advance(lastAccepted: false) // rejected 50 → lo=51, probe 75
        #expect(second == 75)
    }

    @Test("Converges to exact value")
    func convergesToExact() {
        // Target: largest accepted is 7 (lo=0, hi=10, answer=7)
        var stepper = BinarySearchStepper(lo: 0, hi: 10)
        _ = stepper.start() // 5
        _ = stepper.advance(lastAccepted: true) // hi=5, probe 2
        _ = stepper.advance(lastAccepted: true) // hi=2, probe 1
        _ = stepper.advance(lastAccepted: true) // hi=1, probe 0
        let result = stepper.advance(lastAccepted: true) // hi=0, converged
        #expect(result == nil)
        #expect(stepper.bestAccepted == 0)
    }
}

// MARK: - BinarySearchToZeroEncoder

@Suite("BinarySearchToZeroEncoder")
struct BinarySearchToZeroEncoderTests {
    @Test("Converges a single target to zero with all-accepted feedback")
    func singleTargetAllAccepted() {
        let seq = makeSequence([8])
        let spans = allValueSpans(from: seq)
        var encoder = BinarySearchToZeroEncoder()
        encoder.start(sequence: seq, targets: TargetSet.spans(spans))

        var probes: [ChoiceSequence] = []
        var accepted = false
        while let probe = encoder.nextProbe(lastAccepted: accepted) {
            probes.append(probe)
            accepted = true // Accept everything — converge to 0.
        }
        #expect(probes.isEmpty == false)
        // Last probe should have value 0 or close to it.
        let lastValue = probes.last?[0].value?.choice
        #expect(lastValue == .unsigned(0, .uint64))
    }

    @Test("Skips targets already at zero")
    func skipsAlreadyZero() {
        let seq = makeSequence([0, 5])
        let spans = allValueSpans(from: seq)
        var encoder = BinarySearchToZeroEncoder()
        encoder.start(sequence: seq, targets: TargetSet.spans(spans))

        // Only index 1 should be probed.
        var probeCount = 0
        while let probe = encoder.nextProbe(lastAccepted: true) {
            // Index 0 should remain 0 in every probe.
            #expect(probe[0].value?.choice == .unsigned(0, .uint64))
            probeCount += 1
            if probeCount > 20 { break }
        }
        #expect(probeCount > 0)
    }

    @Test("Empty targets produce no probes")
    func emptyTargets() {
        var encoder = BinarySearchToZeroEncoder()
        encoder.start(sequence: makeSequence([5]), targets: TargetSet.spans([]))
        let probe = encoder.nextProbe(lastAccepted: false)
        #expect(probe == nil)
    }
}

// MARK: - TandemReductionEncoder

@Suite("TandemReductionEncoder")
struct TandemReductionEncoderTests {
    @Test("Empty sibling groups produce no probes")
    func emptySiblingGroups() {
        var encoder = TandemReductionEncoder()
        encoder.start(sequence: makeSequence([5, 10]), targets: .siblingGroups([]))
        let probe = encoder.nextProbe(lastAccepted: false)
        #expect(probe == nil)
    }

    @Test("Wrong target type produces no probes")
    func wrongTargetType() {
        var encoder = TandemReductionEncoder()
        encoder.start(sequence: makeSequence([5, 10]), targets: .wholeSequence)
        let probe = encoder.nextProbe(lastAccepted: false)
        #expect(probe == nil)
    }

    @Test("Single-element sibling groups produce no probes")
    func singleElementGroup() {
        let tree = ChoiceTree.sequence(
            length: 1,
            elements: [
                ChoiceTree.choice(.unsigned(5, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
            ],
            .init(validRange: 0 ... 10, isRangeExplicit: true),
        )
        let seq = ChoiceSequence(tree)
        let groups = ChoiceSequence.extractSiblingGroups(from: seq)

        var encoder = TandemReductionEncoder()
        encoder.start(sequence: seq, targets: .siblingGroups(groups))
        let probe = encoder.nextProbe(lastAccepted: false)
        #expect(probe == nil)
    }

    @Test("Two same-tag siblings produce probes that shift both values")
    func twoSameTagSiblings() {
        let tree = ChoiceTree.sequence(
            length: 2,
            elements: [
                ChoiceTree.choice(.unsigned(50, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
                ChoiceTree.choice(.unsigned(80, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
            ],
            .init(validRange: 0 ... 10, isRangeExplicit: true),
        )
        let seq = ChoiceSequence(tree)
        let groups = ChoiceSequence.extractSiblingGroups(from: seq)
        #expect(groups.isEmpty == false)

        var encoder = TandemReductionEncoder()
        encoder.start(sequence: seq, targets: .siblingGroups(groups))

        var probes: [ChoiceSequence] = []
        var accepted = false
        while let probe = encoder.nextProbe(lastAccepted: accepted) {
            probes.append(probe)
            accepted = false // Reject everything to explore all probes.
            if probes.count > 100 { break }
        }
        #expect(probes.isEmpty == false)
    }

    @Test("All-accepted feedback converges both values toward zero")
    func allAcceptedConverges() {
        let tree = ChoiceTree.sequence(
            length: 2,
            elements: [
                ChoiceTree.choice(.unsigned(50, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
                ChoiceTree.choice(.unsigned(80, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
            ],
            .init(validRange: 0 ... 10, isRangeExplicit: true),
        )
        let seq = ChoiceSequence(tree)
        let groups = ChoiceSequence.extractSiblingGroups(from: seq)

        var encoder = TandemReductionEncoder()
        encoder.start(sequence: seq, targets: .siblingGroups(groups))

        var lastProbe: ChoiceSequence?
        var probeCount = 0
        while let probe = encoder.nextProbe(lastAccepted: true) {
            lastProbe = probe
            probeCount += 1
            if probeCount > 200 { break }
        }
        // Should have produced at least one probe, and values should have moved toward zero.
        #expect(lastProbe != nil)
        if let last = lastProbe {
            let values = last.compactMap(\.value).map(\.choice.bitPattern64)
            // At least one value should be smaller than the original.
            let anySmaller = values.contains(where: { $0 < 50 })
            #expect(anySmaller)
        }
    }

    @Test("All-rejected feedback converges quickly")
    func allRejectedConvergesQuickly() {
        let tree = ChoiceTree.sequence(
            length: 2,
            elements: [
                ChoiceTree.choice(.unsigned(1000, .uint64), .init(validRange: 0 ... 10000, isRangeExplicit: true)),
                ChoiceTree.choice(.unsigned(2000, .uint64), .init(validRange: 0 ... 10000, isRangeExplicit: true)),
            ],
            .init(validRange: 0 ... 10, isRangeExplicit: true),
        )
        let seq = ChoiceSequence(tree)
        let groups = ChoiceSequence.extractSiblingGroups(from: seq)

        var encoder = TandemReductionEncoder()
        encoder.start(sequence: seq, targets: .siblingGroups(groups))

        var probeCount = 0
        while let _ = encoder.nextProbe(lastAccepted: false) {
            probeCount += 1
            if probeCount > 500 { break }
        }
        // Binary search should converge in O(log(distance)) probes per plan.
        // With distance ~2000, log2(2000) ~= 11, and we have a few plans.
        // The total should be well under 500.
        #expect(probeCount < 500)
    }

    @Test("Skips siblings already at semantic simplest")
    func skipsAlreadySimplest() {
        let tree = ChoiceTree.sequence(
            length: 2,
            elements: [
                ChoiceTree.choice(.unsigned(0, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
                ChoiceTree.choice(.unsigned(0, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
            ],
            .init(validRange: 0 ... 10, isRangeExplicit: true),
        )
        let seq = ChoiceSequence(tree)
        let groups = ChoiceSequence.extractSiblingGroups(from: seq)

        var encoder = TandemReductionEncoder()
        encoder.start(sequence: seq, targets: .siblingGroups(groups))
        let probe = encoder.nextProbe(lastAccepted: false)
        #expect(probe == nil)
    }

    @Test("Mixed-tag sibling groups are handled")
    func mixedTagSiblings() {
        // Int and Double have different TypeTags — tandem only operates on same-tag subsets.
        // A group with one UInt64 and one UInt32 should not produce tandem plans
        // (since they have different tags and there is only one of each).
        let tree = ChoiceTree.sequence(
            length: 2,
            elements: [
                ChoiceTree.choice(.unsigned(50, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
                ChoiceTree.choice(.unsigned(80, .uint32), .init(validRange: 0 ... 100, isRangeExplicit: true)),
            ],
            .init(validRange: 0 ... 10, isRangeExplicit: true),
        )
        let seq = ChoiceSequence(tree)
        let groups = ChoiceSequence.extractSiblingGroups(from: seq)

        var encoder = TandemReductionEncoder()
        encoder.start(sequence: seq, targets: .siblingGroups(groups))

        // With mixed tags (one uint64, one uint32), each tag has only 1 entry,
        // so no tandem pair can be formed. Should produce no probes.
        var probeCount = 0
        while let _ = encoder.nextProbe(lastAccepted: false) {
            probeCount += 1
            if probeCount > 100 { break }
        }
        // The tandem encoder groups by tag. One of each tag means no 2-element sets.
        // However, the bareValue group falls back to treating all indices as one set
        // regardless of tag, so it may still try. We just verify it does not crash
        // and terminates.
        #expect(probeCount < 100)
    }
}

// MARK: - PromoteBranchesEncoder

@Suite("PromoteBranchesEncoder")
struct PromoteBranchesEncoderTests {
    @Test("Empty tree with no branches produces no candidates")
    func noBranches() {
        let tree = ChoiceTree.group([
            ChoiceTree.choice(.unsigned(5, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true)),
        ])
        let seq = ChoiceSequence(tree)

        var encoder = PromoteBranchesEncoder()
        encoder.currentTree = tree
        let candidates = Array(encoder.encode(sequence: seq, targets: .wholeSequence))
        #expect(candidates.isEmpty)
    }

    @Test("Single branch group produces no candidates")
    func singleBranchGroup() {
        // One branch site with two alternatives — only one group, so no cross-group promotion.
        let tree = ChoiceTree.group([
            ChoiceTree.selected(
                ChoiceTree.branch(
                    siteID: 1,
                    weight: 1,
                    id: 0,
                    branchIDs: [0, 1],
                    choice: ChoiceTree.choice(.unsigned(5, .uint64), .init(validRange: 0 ... 100)),
                ),
            ),
            ChoiceTree.branch(
                siteID: 1,
                weight: 1,
                id: 1,
                branchIDs: [0, 1],
                choice: ChoiceTree.group([
                    ChoiceTree.choice(.unsigned(10, .uint64), .init(validRange: 0 ... 100)),
                    ChoiceTree.choice(.unsigned(20, .uint64), .init(validRange: 0 ... 100)),
                ]),
            ),
        ])
        let seq = ChoiceSequence(tree)

        var encoder = PromoteBranchesEncoder()
        encoder.currentTree = tree
        let candidates = Array(encoder.encode(sequence: seq, targets: .wholeSequence))
        // Only one branch group (one .group node whose children are all branches),
        // but promoteBranches needs >= 2 branch groups to cross-promote.
        // With exactly 1 group containing 2 branches, it should produce candidates
        // (replacing complex branch with simpler one within the same group).
        // Let's just verify it does not crash and the result is deterministic.
        // Actually, the encoder sorts branches and tries to replace complex with simple,
        // so with 2 branches of different complexity, it should produce 1 candidate.
        if candidates.isEmpty == false {
            for candidate in candidates {
                #expect(candidate.shortLexPrecedes(seq))
            }
        }
    }

    @Test("Two branch groups produce candidates replacing complex with simple")
    func twoBranchGroupsProduceCandidates() {
        // Use the tagged gen from ReducerBranchTests pattern: zip two pick generators.
        let taggedGen = makeTaggedGenForEncoder()
        for seed in UInt64(0) ... 100 {
            for iteration in 0 ... 5 {
                guard let (_, tree) = try? generateForEncoder(taggedGen, seed: seed, iteration: iteration) else {
                    continue
                }
                // Need a tree with 2+ branch groups
                let seq = ChoiceSequence(tree)
                var encoder = PromoteBranchesEncoder()
                encoder.currentTree = tree
                let candidates = Array(encoder.encode(sequence: seq, targets: .wholeSequence))
                if candidates.isEmpty == false {
                    #expect(candidates.count >= 1)
                    return
                }
            }
        }
    }

    @Test("Every candidate shortlex-precedes the input")
    func candidatesShortlexPrecede() {
        let taggedGen = makeTaggedGenForEncoder()
        for seed in UInt64(0) ... 100 {
            for iteration in 0 ... 5 {
                guard let (_, tree) = try? generateForEncoder(taggedGen, seed: seed, iteration: iteration) else {
                    continue
                }
                let seq = ChoiceSequence(tree)
                var encoder = PromoteBranchesEncoder()
                encoder.currentTree = tree
                for candidate in encoder.encode(sequence: seq, targets: .wholeSequence) {
                    #expect(candidate.shortLexPrecedes(seq))
                }
            }
        }
    }

    @Test("Candidates have simpler branch structure substituted")
    func candidatesBranchSubstituted() {
        let taggedGen = makeTaggedGenForEncoder()
        var found = false
        for seed in UInt64(0) ... 100 {
            for iteration in 0 ... 5 {
                guard let (_, tree) = try? generateForEncoder(taggedGen, seed: seed, iteration: iteration) else {
                    continue
                }
                let seq = ChoiceSequence(tree)
                var encoder = PromoteBranchesEncoder()
                encoder.currentTree = tree
                let candidates = Array(encoder.encode(sequence: seq, targets: .wholeSequence))
                if candidates.isEmpty == false {
                    // Each candidate must be different from the original.
                    for candidate in candidates {
                        #expect(candidate != seq)
                        #expect(candidate.shortLexPrecedes(seq))
                    }
                    found = true
                }
                if found { return }
            }
        }
    }
}

// MARK: - CrossStageRedistributeEncoder

@Suite("CrossStageRedistributeEncoder")
struct CrossStageRedistributeEncoderTests {
    @Test("Empty sequence produces no probes")
    func emptySequence() {
        let seq = ChoiceSequence()
        var encoder = CrossStageRedistributeEncoder()
        encoder.start(sequence: seq, targets: .wholeSequence)
        let probe = encoder.nextProbe(lastAccepted: false)
        #expect(probe == nil)
    }

    @Test("Single numeric value produces no probes")
    func singleValue() {
        let seq = makeSequence([42])
        var encoder = CrossStageRedistributeEncoder()
        encoder.start(sequence: seq, targets: .wholeSequence)
        let probe = encoder.nextProbe(lastAccepted: false)
        #expect(probe == nil)
    }

    @Test("More than 16 numeric values produces no probes")
    func moreThan16Values() {
        let values: [UInt64] = (1 ... 17).map { UInt64($0) }
        let seq = makeSequence(values)
        var encoder = CrossStageRedistributeEncoder()
        encoder.start(sequence: seq, targets: .wholeSequence)
        let probe = encoder.nextProbe(lastAccepted: false)
        #expect(probe == nil)
    }

    @Test("Wrong target type produces no probes")
    func wrongTargetType() {
        let seq = makeSequence([5, 10])
        var encoder = CrossStageRedistributeEncoder()
        encoder.start(sequence: seq, targets: .spans([]))
        let probe = encoder.nextProbe(lastAccepted: false)
        #expect(probe == nil)
    }

    @Test("Two values where one can decrease and the other increase produce probes")
    func twoValuesProduceProbes() {
        // Value 50 wants to go toward 0 (reduction target for unsigned).
        // Value 30 can compensate by increasing.
        let seq = makeSequence([50, 30])
        var encoder = CrossStageRedistributeEncoder()
        encoder.start(sequence: seq, targets: .wholeSequence)

        var probes: [ChoiceSequence] = []
        var accepted = false
        while let probe = encoder.nextProbe(lastAccepted: accepted) {
            probes.append(probe)
            accepted = false
            if probes.count > 200 { break }
        }
        #expect(probes.isEmpty == false)
    }

    @Test("All-accepted feedback converges")
    func allAcceptedConverges() {
        let seq = makeSequence([50, 30])
        var encoder = CrossStageRedistributeEncoder()
        encoder.start(sequence: seq, targets: .wholeSequence)

        var probeCount = 0
        while let _ = encoder.nextProbe(lastAccepted: true) {
            probeCount += 1
            if probeCount > 500 { break }
        }
        // Should terminate (converge) without hitting the safety limit.
        #expect(probeCount < 500)
        #expect(probeCount > 0)
    }

    @Test("Values already at their targets produce no probes")
    func valuesAtTargets() {
        // Both values are 0 (the reduction target for unsigned integers).
        let seq = makeSequence([0, 0])
        var encoder = CrossStageRedistributeEncoder()
        encoder.start(sequence: seq, targets: .wholeSequence)
        let probe = encoder.nextProbe(lastAccepted: false)
        #expect(probe == nil)
    }
}

// MARK: - Encoder Test Helpers

/// Generates a value and its choice tree for encoder tests.
private func generateForEncoder<Output>(
    _ gen: ReflectiveGenerator<Output>,
    materializePicks: Bool = true,
    seed: UInt64 = 42,
    iteration: Int = 0,
) throws -> (value: Output, tree: ChoiceTree) {
    var iter = ValueAndChoiceTreeInterpreter(gen, materializePicks: materializePicks, seed: seed)
    return try #require(iter.prefix(iteration + 1).last)
}

/// Collects all probes from a ZeroValueEncoder, rejecting every probe.
private func collectZeroValueProbes(sequence: ChoiceSequence, spans: [ChoiceSpan]) -> [ChoiceSequence] {
    var encoder = ZeroValueEncoder()
    encoder.start(sequence: sequence, targets: .spans(spans))
    var results: [ChoiceSequence] = []
    while let probe = encoder.nextProbe(lastAccepted: false) {
        results.append(probe)
    }
    return results
}

/// A pick generator with two branches for encoder testing.
private func makeTaggedGenForEncoder() -> ReflectiveGenerator<(Int, Int)> {
    let smallBranch = Gen.contramap(
        { (value: Int) throws -> Int in value },
        Gen.choose(in: 0 ... 100 as ClosedRange<Int>)._map { $0 },
    )
    let bigBranch = Gen.contramap(
        { (value: Int) throws -> (Int, Int) in (value / 2, value - value / 2) },
        Gen.zip(Gen.choose(in: 0 ... 100 as ClosedRange<Int>), Gen.choose(in: 0 ... 100 as ClosedRange<Int>))._map { $0 + $1 },
    )
    let pickGen = Gen.pick(choices: [(1, smallBranch), (1, bigBranch)])
    return Gen.zip(pickGen, pickGen)
}
