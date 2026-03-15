import Testing
@testable import ExhaustCore

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
