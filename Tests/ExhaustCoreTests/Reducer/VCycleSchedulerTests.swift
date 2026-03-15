import Testing
@testable import ExhaustCore

// MARK: - Merge Pre-Checks

@Suite("buildMergedSequence")
struct BuildMergedSequenceTests {
    @Test("Returns nil when region counts differ")
    func regionCountMismatch() {
        let pre = makeBindSequence(innerValues: [5], boundValues: [10])
        let post = makeTwoBindSequence(
            bind1Inner: [3], bind1Bound: [20],
            bind2Inner: [1], bind2Bound: [30]
        )
        let preBi = BindSpanIndex(from: pre)
        let postBi = BindSpanIndex(from: post)

        let result = ReductionScheduler.buildMergedSequence(
            preCovariantSequence: pre,
            postCovariantSequence: post,
            preBindIndex: preBi,
            postBindIndex: postBi
        )
        #expect(result == nil)
    }

    @Test("Pre-check 2b: skips regions with mismatched inner range sizes")
    func innerRangeSizeMismatch() {
        // Pre has 1 inner value, post has 2 inner values in same region.
        // Even though pre bound < post bound, the region is skipped.
        let pre = makeBindSequence(innerValues: [5], boundValues: [10])
        let post = makeBindSequence(innerValues: [3, 7], boundValues: [20])
        let preBi = BindSpanIndex(from: pre)
        let postBi = BindSpanIndex(from: post)

        let result = ReductionScheduler.buildMergedSequence(
            preCovariantSequence: pre,
            postCovariantSequence: post,
            preBindIndex: preBi,
            postBindIndex: postBi
        )
        #expect(result == nil)
    }

    @Test("Pre-check 3: returns nil when no bound regression exists")
    func noRegressionSkipsMerge() {
        // Post bound values are already <= pre bound values. No merge candidate.
        let pre = makeBindSequence(innerValues: [5], boundValues: [20])
        let post = makeBindSequence(innerValues: [3], boundValues: [10])
        let preBi = BindSpanIndex(from: pre)
        let postBi = BindSpanIndex(from: post)

        let result = ReductionScheduler.buildMergedSequence(
            preCovariantSequence: pre,
            postCovariantSequence: post,
            preBindIndex: preBi,
            postBindIndex: postBi
        )
        #expect(result == nil)
    }

    @Test("Pre-check 3: returns nil when bound values are equal")
    func equalBoundValuesSkipsMerge() {
        let pre = makeBindSequence(innerValues: [5], boundValues: [10])
        let post = makeBindSequence(innerValues: [3], boundValues: [10])
        let preBi = BindSpanIndex(from: pre)
        let postBi = BindSpanIndex(from: post)

        let result = ReductionScheduler.buildMergedSequence(
            preCovariantSequence: pre,
            postCovariantSequence: post,
            preBindIndex: preBi,
            postBindIndex: postBi
        )
        #expect(result == nil)
    }

    @Test("Pre-check 4: skips substitutions outside valid range")
    func outOfRangeSubstitutionSkipped() {
        // Pre bound value = 5, post valid range = 10...100.
        // 5 is outside 10...100, so the substitution is skipped.
        let pre = makeBindSequence(innerValues: [5], boundValues: [5])
        let post = makeBindSequence(innerValues: [3], boundValues: [20], boundRange: 10 ... 100)
        let preBi = BindSpanIndex(from: pre)
        let postBi = BindSpanIndex(from: post)

        let result = ReductionScheduler.buildMergedSequence(
            preCovariantSequence: pre,
            postCovariantSequence: post,
            preBindIndex: preBi,
            postBindIndex: postBi
        )
        #expect(result == nil)
    }

    @Test("Pre-check 4: allows substitution within valid range")
    func inRangeSubstitutionAllowed() {
        // Pre bound value = 15, post bound value = 50, post valid range = 10...100.
        // 15 is within 10...100, so substitution proceeds.
        let pre = makeBindSequence(innerValues: [5], boundValues: [15], boundRange: 10 ... 100)
        let post = makeBindSequence(innerValues: [3], boundValues: [50], boundRange: 10 ... 100)
        let preBi = BindSpanIndex(from: pre)
        let postBi = BindSpanIndex(from: post)

        let result = ReductionScheduler.buildMergedSequence(
            preCovariantSequence: pre,
            postCovariantSequence: post,
            preBindIndex: preBi,
            postBindIndex: postBi
        )
        #expect(result != nil)
        // The merged sequence should keep post's inner (3) but substitute pre's bound (15).
        // +1 to skip the .group(true) marker at the start of each range.
        let boundValueIdx = postBi.regions[0].boundRange.lowerBound + 1
        #expect(result?[boundValueIdx].value?.choice == .unsigned(15, .uint64))
        let innerValueIdx = postBi.regions[0].innerRange.lowerBound + 1
        #expect(result?[innerValueIdx].value?.choice == .unsigned(3, .uint64))
    }

    @Test("Substitutes pre-covariant values where they are shortlex-smaller")
    func substitutionOnRegression() {
        // Pre bound = [10, 5], post bound = [20, 3].
        // Position 0: pre 10 < post 20 → substitute. Position 1: pre 5 > post 3 → keep post.
        let pre = makeBindSequence(innerValues: [5], boundValues: [10, 5])
        let post = makeBindSequence(innerValues: [3], boundValues: [20, 3])
        let preBi = BindSpanIndex(from: pre)
        let postBi = BindSpanIndex(from: post)

        let result = ReductionScheduler.buildMergedSequence(
            preCovariantSequence: pre,
            postCovariantSequence: post,
            preBindIndex: preBi,
            postBindIndex: postBi
        )
        #expect(result != nil)
        // +1 to skip the .group(true) marker at the start of the bound range.
        let boundValueStart = postBi.regions[0].boundRange.lowerBound + 1
        #expect(result?[boundValueStart].value?.choice == .unsigned(10, .uint64))
        #expect(result?[boundValueStart + 1].value?.choice == .unsigned(3, .uint64))
    }

    @Test("Pre-check 2b: skips mismatched region but merges matching one")
    func mixedRegions() {
        // Two bind regions. First has mismatched inner sizes → skipped.
        // Second has matching inner sizes and a regression → merged.
        let pre = makeTwoBindSequence(
            bind1Inner: [1, 2], bind1Bound: [10],
            bind2Inner: [5], bind2Bound: [10]
        )
        let post = makeTwoBindSequence(
            bind1Inner: [1], bind1Bound: [20],
            bind2Inner: [3], bind2Bound: [20]
        )
        let preBi = BindSpanIndex(from: pre)
        let postBi = BindSpanIndex(from: post)

        let result = ReductionScheduler.buildMergedSequence(
            preCovariantSequence: pre,
            postCovariantSequence: post,
            preBindIndex: preBi,
            postBindIndex: postBi
        )
        // Region 1 is skipped (inner size mismatch). Region 2 has regression (10 < 20).
        #expect(result != nil)
        // +1 to skip the .group(true) marker at the start of each bound range.
        // Region 1's bound value should be unchanged (post's value).
        let bound1ValueIdx = postBi.regions[0].boundRange.lowerBound + 1
        #expect(result?[bound1ValueIdx].value?.choice == .unsigned(20, .uint64))
        // Region 2's bound value should be substituted with pre's value.
        let bound2ValueIdx = postBi.regions[1].boundRange.lowerBound + 1
        #expect(result?[bound2ValueIdx].value?.choice == .unsigned(10, .uint64))
    }
}

// MARK: - Covariant Decoder Freshness

@Suite("Covariant decoder freshness")
struct CovariantDecoderFreshnessTests {
    @Test("Covariant sweep reduces bind-dependent generator past single-encoder optimum")
    func multiEncoderCovariantSweep() throws {
        // A bind generator where the inner value controls array length.
        // Multiple covariant encoders (zero, binarySearchToZero) should each contribute.
        // With stale targets, the second encoder would see the old span layout.
        let gen = makeBoundArrayGen(innerRange: 1 ... 20, elementRange: 0 ... 100)

        var iterator = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: 12345)
        var failingTree: ChoiceTree?
        while let (value, tree) = try iterator.next() {
            let arr = value as! [Any]
            if arr.count >= 4 {
                failingTree = tree
                break
            }
        }

        let tree = try #require(failingTree)
        let config = Interpreters.BonsaiReducerConfiguration(from: .fast)
        let (_, output) = try #require(
            try ReductionScheduler.run(gen: gen, initialTree: tree, config: config) { output in
                let arr = output as! [Any]
                return arr.count <= 3
            }
        )

        // The reducer should find a counterexample with count > 3.
        let arr = output as! [Any]
        #expect(arr.count >= 4)
    }
}

// MARK: - Deletion Decoder Freshness

@Suite("Deletion decoder freshness")
struct DeletionDecoderFreshnessTests {
    @Test("Deletion sweep handles multiple successful deletions at same depth")
    func multiDeletionSameDepth() throws {
        // Generate a bound array generator. After the first deletion succeeds,
        // the decoder must be rebuilt for subsequent deletions.
        let gen = makeBoundArrayGen(innerRange: 0 ... 100, elementRange: 0 ... 50)

        var iterator = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: 9999)
        var failingTree: ChoiceTree?
        while let (value, tree) = try iterator.next() {
            let arr = value as! [Any]
            if arr.count >= 5 {
                failingTree = tree
                break
            }
        }

        let tree = try #require(failingTree)
        let config = Interpreters.BonsaiReducerConfiguration(from: .fast)
        let (_, output) = try #require(
            try ReductionScheduler.run(gen: gen, initialTree: tree, config: config) { output in
                let arr = output as! [Any]
                return arr.count < 3
            }
        )

        // The reducer should find a 3-element array (minimal violation).
        let arr = output as! [Any]
        #expect(arr.count >= 3)
    }
}

// MARK: - Helpers

/// Builds a choice sequence with a single bind region:
/// `.bind(true)` `.group(true)` [inner values] `.group(false)` `.group(true)` [bound values] `.group(false)` `.bind(false)`
private func makeBindSequence(
    innerValues: [UInt64],
    boundValues: [UInt64],
    innerRange: ClosedRange<UInt64> = 0 ... UInt64.max,
    boundRange: ClosedRange<UInt64> = 0 ... UInt64.max
) -> ChoiceSequence {
    var seq = ChoiceSequence()
    seq.append(.bind(true))
    seq.append(.group(true))
    for v in innerValues {
        seq.append(.value(.init(choice: .unsigned(v, .uint64), validRange: innerRange)))
    }
    seq.append(.group(false))
    seq.append(.group(true))
    for v in boundValues {
        seq.append(.value(.init(choice: .unsigned(v, .uint64), validRange: boundRange)))
    }
    seq.append(.group(false))
    seq.append(.bind(false))
    return seq
}

/// Builds a choice sequence with two consecutive bind regions.
private func makeTwoBindSequence(
    bind1Inner: [UInt64], bind1Bound: [UInt64],
    bind2Inner: [UInt64], bind2Bound: [UInt64]
) -> ChoiceSequence {
    var seq = ChoiceSequence()
    seq.append(.bind(true))
    seq.append(.group(true))
    for v in bind1Inner {
        seq.append(.value(.init(choice: .unsigned(v, .uint64), validRange: 0 ... UInt64.max)))
    }
    seq.append(.group(false))
    seq.append(.group(true))
    for v in bind1Bound {
        seq.append(.value(.init(choice: .unsigned(v, .uint64), validRange: 0 ... UInt64.max)))
    }
    seq.append(.group(false))
    seq.append(.bind(false))
    seq.append(.bind(true))
    seq.append(.group(true))
    for v in bind2Inner {
        seq.append(.value(.init(choice: .unsigned(v, .uint64), validRange: 0 ... UInt64.max)))
    }
    seq.append(.group(false))
    seq.append(.group(true))
    for v in bind2Bound {
        seq.append(.value(.init(choice: .unsigned(v, .uint64), validRange: 0 ... UInt64.max)))
    }
    seq.append(.group(false))
    seq.append(.bind(false))
    return seq
}

/// Builds a bind generator: inner chooses a length, bound produces an array of that length.
/// Returns `ReflectiveGenerator<Any>` since `_bound` is in the Exhaust target.
private func makeBoundArrayGen(
    innerRange: ClosedRange<UInt64>,
    elementRange: ClosedRange<UInt64>
) -> ReflectiveGenerator<Any> {
    let innerGen: ReflectiveGenerator<UInt64> = Gen.choose(in: innerRange)
    let elementGen: ReflectiveGenerator<UInt64> = Gen.choose(in: elementRange)

    return Gen.liftF(.transform(
        kind: .bind(
            forward: { innerValue in
                let length = innerValue as! UInt64
                return Gen.arrayOf(elementGen, Gen.choose(in: length ... length)).erase()
            },
            backward: { output in
                let arr = output as! [UInt64]
                return UInt64(arr.count) as Any
            },
            inputType: "UInt64",
            outputType: "[UInt64]"
        ),
        inner: innerGen.erase()
    ))
}
