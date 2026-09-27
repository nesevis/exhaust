import Testing
@testable import ExhaustCore

@Suite("ConstantArmReencoder")
struct ConstantArmReencoderTests {
    @Test("Unselected reproducible constants are excluded independently")
    func unselectedReproducibleConstantsAreExcluded() throws {
        let generator = Gen.pick(choices: [
            (1, Gen.asciiString().gen),
            (1, Gen.just("alpha")),
            (1, Gen.just("beta")),
        ])
        let initialTree = try #require(try Interpreters.reflect(generator, with: "gamma"))
        let initialSequence = ChoiceSequence.flatten(initialTree)

        let result = try #require(ConstantArmReencoder.reencode(
            sequence: initialSequence,
            gen: generator.erase()
        ))

        #expect(Set(result.excludedPivots.map(\.constantBranchID)) == [1, 2])
        #expect(branchIDs(in: result.sequence).first == 0)
        guard case let .success(value, _, _) = Materializer.materialize(
            generator,
            context: .init(prefix: result.sequence, mode: .exact, fallbackTree: result.tree)
        ) else {
            Issue.record("The normalized sequence did not materialize")
            return
        }
        #expect(value == "gamma")
    }

    @Test("A selected constant is re-encoded while an unreproducible constant remains available")
    func selectedConstantReencodesIndependently() throws {
        let generator = Gen.pick(choices: [
            (1, Gen.just("alpha")),
            (1, Gen.just("café")),
            (1, Gen.asciiString().gen),
        ])
        let initialTree = try #require(try Interpreters.reflect(generator, with: "alpha"))

        let result = try #require(ConstantArmReencoder.reencode(
            sequence: ChoiceSequence.flatten(initialTree),
            gen: generator.erase()
        ))

        #expect(Set(result.excludedPivots.map(\.constantBranchID)) == [0])
        #expect(branchIDs(in: result.sequence).first == 2)
        guard case let .success(value, _, _) = Materializer.materialize(
            generator,
            context: .init(prefix: result.sequence, mode: .exact, fallbackTree: result.tree)
        ) else {
            Issue.record("The re-encoded sequence did not materialize")
            return
        }
        #expect(value == "alpha")
    }

    @Test("A non-ASCII constant is not re-encoded through an ASCII sibling")
    func nonASCIIConstantIsNotReencoded() throws {
        let generator = Gen.pick(choices: [
            (1, Gen.asciiString().gen),
            (1, Gen.just("café")),
        ])
        let initialTree = try #require(try Interpreters.reflect(generator, with: "plain"))

        let result = ConstantArmReencoder.reencode(
            sequence: ChoiceSequence.flatten(initialTree),
            gen: generator.erase()
        )

        #expect(result == nil)
    }

    @Test("Choice-free siblings do not re-encode each other")
    func choiceFreeSiblingsDoNotReencodeEachOther() throws {
        let generator = Gen.pick(choices: [
            (1, Gen.just("alpha")),
            (1, Gen.just("beta")),
        ])
        let initialTree = try #require(try Interpreters.reflect(generator, with: "alpha"))

        let result = ConstantArmReencoder.reencode(
            sequence: ChoiceSequence.flatten(initialTree),
            gen: generator.erase()
        )

        #expect(result == nil)
    }

    @Test("Excluded constant-arm pivots survive a structural graph rebuild")
    func exclusionSurvivesRebuild() throws {
        let generator = Gen.pick(choices: [
            (1, Gen.asciiString().gen),
            (1, Gen.just("alpha")),
        ])
        let initialTree = try #require(try Interpreters.reflect(generator, with: "alpha"))
        var machine = ReductionMachine(
            gen: generator,
            initialTree: initialTree,
            initialOutput: "alpha",
            config: Interpreters.ReducerConfiguration(maxStalls: 4),
            collectStats: false,
            property: { $0.contains("alpha") == false }
        )
        let excludedPivots = machine.graph.excludedPivots
        #expect(Set(excludedPivots.map(\.constantBranchID)) == [1])

        _ = machine.rebuildAndUpdateGraph()

        #expect(machine.graph.excludedPivots == excludedPivots)
        #expect(branchPivotTargets(in: ChoiceGraph.build(from: machine.tree)).contains(1))
        #expect(branchPivotTargets(in: machine.graph).contains(1) == false)
    }
}

private func branchIDs(in sequence: ChoiceSequence) -> [UInt64] {
    sequence.compactMap { value in
        guard case let .branch(branch) = value else {
            return nil
        }
        return branch.id
    }
}

/// Target branch IDs of every branch pivot ``ReplacementQuery`` proposes on `graph`.
private func branchPivotTargets(in graph: ChoiceGraph) -> [UInt64] {
    ReplacementQuery.build(graph: graph).compactMap { scope in
        guard case let .branchPivot(_, targetBranchID) = scope else {
            return nil
        }
        return targetBranchID
    }
}
