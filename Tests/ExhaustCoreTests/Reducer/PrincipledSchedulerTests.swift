import Testing
@testable import ExhaustCore

// MARK: - PrincipledScheduler Tests

@Suite("PrincipledScheduler")
struct PrincipledSchedulerTests {
    /// Configuration that uses the principled scheduler.
    private static let principledConfig = Interpreters.BonsaiReducerConfiguration(
        from: .fast, scheduler: .principled
    )

    // MARK: - 1. Non-bind generator parity

    @Test("Non-bind integer generator produces valid counterexample")
    func nonBindGeneratorParity() throws {
        let gen: ReflectiveGenerator<UInt64> = Gen.choose(in: 0 ... 1000)

        let (tree, _) = try findFailingTree(gen: gen, seed: 42) { value in
            value < 50
        }

        let (_, output) = try #require(
            try PrincipledScheduler.run(
                gen: gen, initialTree: tree, config: Self.principledConfig
            ) { $0 < 50 }
        )

        #expect(output >= 50)
    }

    // MARK: - 2. Bind-dependent array length shrinks correctly

    @Test("Bind-dependent array length shrinks to minimal violation")
    func bindDependentArrayLength() throws {
        let gen = makeBoundArrayGen(innerRange: 1 ... 20, elementRange: 0 ... 100)

        let (tree, _) = try findFailingTree(gen: gen, seed: 42) { output in
            let arr = output as! [UInt64]
            return arr.count <= 3
        }

        let (_, output) = try #require(
            try PrincipledScheduler.run(
                gen: gen, initialTree: tree, config: Self.principledConfig
            ) { output in
                let arr = output as! [UInt64]
                return arr.count <= 3
            }
        )

        let arr = output as! [UInt64]
        #expect(arr.count >= 4)
        #expect(arr.count <= 6, "Expected near-minimal array length, got \(arr.count)")
    }

    // MARK: - 3. Zip of two binds shrinks correctly

    @Test("Zip of two binds shrinks both bind-inner values")
    func zipOfTwoBinds() throws {
        let singleBind: ReflectiveGenerator<Int> = Gen.liftF(.transform(
            kind: .bind(
                forward: { innerValue -> ReflectiveGenerator<Any> in
                    let number = innerValue as! Int
                    return (Gen.choose(in: 0 ... max(1, number) as ClosedRange<Int>) as ReflectiveGenerator<Int>).erase()
                },
                backward: { finalOutput -> Any in
                    let bound = finalOutput as! Int
                    return bound as Any
                },
                inputType: "Int",
                outputType: "Int"
            ),
            inner: (Gen.choose(in: 0 ... 50 as ClosedRange<Int>)).erase()
        ))

        let gen = Gen.zip(singleBind, singleBind)

        let (tree, _) = try findFailingTree(gen: gen, seed: 999) { pair in
            pair.0 + pair.1 < 20
        }

        let (_, output) = try #require(
            try PrincipledScheduler.run(
                gen: gen, initialTree: tree, config: Self.principledConfig
            ) { pair in
                pair.0 + pair.1 < 20
            }
        )

        #expect(output.0 + output.1 >= 20)
    }

    // MARK: - 4. Phase 1 restart on deletion

    @Test("Phase 1 structural deletion reduces sequence length")
    func phase1DeletionProgress() throws {
        let gen = makeBoundArrayGen(innerRange: 1 ... 20, elementRange: 0 ... 100)

        let (tree, _) = try findFailingTree(gen: gen, seed: 12345) { output in
            let arr = output as! [UInt64]
            return arr.count <= 3
        }

        let sequence = ChoiceSequence.flatten(tree)
        guard let output = try Interpreters.materialize(gen, with: tree, using: sequence) else {
            Issue.record("Failed to materialize initial tree")
            return
        }

        let state = ReductionState(
            gen: gen,
            property: { output in
                let arr = output as! [UInt64]
                return arr.count <= 3
            },
            config: Self.principledConfig,
            sequence: sequence,
            tree: tree,
            output: output,
            initialTree: tree
        )

        state.computeEncoderOrdering()
        let initialLength = state.sequence.count
        var budget = PrincipledScheduler.phase1Budget
        let (_, progress) = try state.runStructuralMinimization(budget: &budget)

        #expect(progress, "Phase 1 should make progress on a deletable bind tree")
        #expect(state.sequence.count <= initialLength, "Sequence should not grow after structural minimization")
    }

    // MARK: - 5. Phase 2 leaf ordering

    @Test("Phase 2 processes bound leaves before independent leaves")
    func phase2LeafOrdering() throws {
        let gen = makeBoundArrayGen(innerRange: 1 ... 10, elementRange: 0 ... 100)

        let (tree, _) = try findFailingTree(gen: gen, seed: 7777) { output in
            let arr = output as! [UInt64]
            return arr.count <= 2
        }

        let sequence = ChoiceSequence.flatten(tree)
        guard let output = try Interpreters.materialize(gen, with: tree, using: sequence) else {
            Issue.record("Failed to materialize")
            return
        }

        let state = ReductionState(
            gen: gen,
            property: { output in
                let arr = output as! [UInt64]
                return arr.count <= 2
            },
            config: Self.principledConfig,
            sequence: sequence,
            tree: tree,
            output: output,
            initialTree: tree
        )

        let bindSpanIndex = BindSpanIndex(from: sequence)
        let dag = DependencyDAG.build(from: sequence, tree: tree, bindIndex: bindSpanIndex)
        let leafRanges = state.computeLeafRanges(dag: dag)

        // Bound leaves should come first in the ordering.
        guard leafRanges.count >= 2 else {
            // Single leaf range is acceptable for some generator shapes.
            return
        }

        let firstLeafInBound = bindSpanIndex.isInBoundSubtree(leafRanges[0].lowerBound)
        let lastLeafInBound = bindSpanIndex.isInBoundSubtree(leafRanges[leafRanges.count - 1].lowerBound)

        // If there are both bound and non-bound leaves, bound should come first.
        if firstLeafInBound == false && lastLeafInBound {
            Issue.record("Bound leaves should be ordered before independent leaves")
        }
    }

    // MARK: - 6. Fingerprint boundary guard

    @Test("Fingerprint guard handles structural change during value minimization")
    func fingerprintBoundaryGuard() throws {
        let gen: ReflectiveGenerator<Any> = Gen.liftF(.transform(
            kind: .bind(
                forward: { innerValue -> ReflectiveGenerator<Any> in
                    let number = innerValue as! UInt64
                    let length = max(1, number)
                    return Gen.arrayOf(
                        Gen.choose(in: 0 ... 100 as ClosedRange<UInt64>),
                        Gen.choose(in: length ... length)
                    ).erase()
                },
                backward: { finalOutput -> Any in
                    let arr = finalOutput as! [UInt64]
                    return UInt64(arr.count) as Any
                },
                inputType: "UInt64",
                outputType: "[UInt64]"
            ),
            inner: Gen.choose(in: 1 ... 50 as ClosedRange<UInt64>).erase()
        ))

        let (tree, _) = try findFailingTree(gen: gen, seed: 31415) { output in
            let arr = output as! [UInt64]
            return arr.count <= 3
        }

        // The key assertion is that the scheduler terminates correctly even when
        // structural changes occur during Phase 2.
        let result = try PrincipledScheduler.run(
            gen: gen, initialTree: tree, config: Self.principledConfig
        ) { output in
            let arr = output as! [UInt64]
            return arr.count <= 3
        }

        let (_, output) = try #require(result)
        let arr = output as! [UInt64]
        #expect(arr.count >= 4)
    }

    // MARK: - 7. Scheduler terminates within budget

    @Test("Scheduler terminates when no reduction is possible")
    func terminatesWithinBudget() throws {
        let gen: ReflectiveGenerator<UInt64> = Gen.choose(in: 0 ... 0)

        var iterator = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: 42)
        let (_, tree) = try #require(try iterator.next())

        let result = try PrincipledScheduler.run(
            gen: gen, initialTree: tree, config: Self.principledConfig
        ) { _ in false }

        #expect(result != nil)
    }

    // MARK: - 8. Full parity with V-cycle

    @Test("Parity with V-cycle on bind-dependent array length", arguments: [
        UInt64(42), UInt64(123), UInt64(999),
    ])
    func parityBoundArray(seed: UInt64) throws {
        let gen = makeBoundArrayGen(innerRange: 1 ... 20, elementRange: 0 ... 100)

        let property: (Any) -> Bool = { output in
            let arr = output as! [UInt64]
            return arr.count <= 3
        }

        let (tree, _) = try findFailingTree(gen: gen, seed: seed, property: property)

        let vCycleConfig = Interpreters.BonsaiReducerConfiguration(from: .fast)
        let vCycleResult = try ReductionScheduler.run(
            gen: gen, initialTree: tree, config: vCycleConfig, property: property
        )

        let principledResult = try PrincipledScheduler.run(
            gen: gen, initialTree: tree, config: Self.principledConfig, property: property
        )

        let vCycleOutput = try #require(vCycleResult).1
        let principledOutput = try #require(principledResult).1

        let vArr = vCycleOutput as! [UInt64]
        let pArr = principledOutput as! [UInt64]

        #expect(vArr.count >= 4)
        #expect(pArr.count >= 4)
        #expect(pArr.count <= vArr.count + 2,
                "Principled produced \(pArr.count) elements vs V-cycle's \(vArr.count)")
    }

    @Test("Parity with V-cycle on simple integer generator", arguments: [
        UInt64(42), UInt64(123), UInt64(999),
    ])
    func paritySimpleInteger(seed: UInt64) throws {
        let gen: ReflectiveGenerator<UInt64> = Gen.choose(in: 0 ... 1000)

        let property: (UInt64) -> Bool = { $0 < 100 }
        let (tree, _) = try findFailingTree(gen: gen, seed: seed, property: property)

        let vCycleConfig = Interpreters.BonsaiReducerConfiguration(from: .fast)
        let vCycleResult = try ReductionScheduler.run(
            gen: gen, initialTree: tree, config: vCycleConfig, property: property
        )

        let principledResult = try PrincipledScheduler.run(
            gen: gen, initialTree: tree, config: Self.principledConfig, property: property
        )

        let vOutput = try #require(vCycleResult).1
        let pOutput = try #require(principledResult).1

        #expect(vOutput >= 100)
        #expect(pOutput >= 100)
    }
}

// MARK: - Helpers

/// Finds the first failing tree for a generator with a given property.
private func findFailingTree<Output>(
    gen: ReflectiveGenerator<Output>,
    seed: UInt64,
    property: @escaping (Output) -> Bool
) throws -> (ChoiceTree, Output) {
    var iterator = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: seed)
    for _ in 0 ..< 200 {
        guard let (value, tree) = try iterator.next() else { continue }
        if property(value) == false {
            return (tree, value)
        }
    }
    throw TestHelperError.noFailingInput
}

/// Builds a bind generator: inner chooses a length, bound produces an array of that length.
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

private enum TestHelperError: Error {
    case noFailingInput
}
