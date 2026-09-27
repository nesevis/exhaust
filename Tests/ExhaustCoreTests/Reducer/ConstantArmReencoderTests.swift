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
            tree: initialTree,
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
            tree: initialTree,
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
            tree: initialTree,
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
            tree: initialTree,
            gen: generator.erase()
        )

        #expect(result == nil)
    }

    @Test("An exclusion applies only to picks whose arms draw from the classified domains")
    func exclusionIsScopedToArmDomains() throws {
        let generator = Gen.zip(sharedLocationPick(in: 0 ... 10), sharedLocationPick(in: 5 ... 10))
        let initialTree = try #require(try Interpreters.reflect(generator, with: (UInt64(5), UInt64(5))))
        let materialized = Materializer.materializeAny(
            generator.erase(),
            context: .init(
                prefix: ChoiceSequence.flatten(initialTree),
                mode: .exact,
                fallbackTree: initialTree,
                materializePicks: true
            )
        )
        guard case let .success(_, fullTree, _) = materialized else {
            Issue.record("The counterexample did not materialize")
            return
        }

        let result = try #require(ConstantArmReencoder.reencode(
            sequence: ChoiceSequence(fullTree),
            tree: fullTree,
            gen: generator.erase()
        ))
        var graph = ChoiceGraph.build(from: result.tree)
        graph.excludedPivots = result.excludedPivots
        let pickNodeIDs = graph.liveNodeIDs.filter { nodeID in
            guard case .pick = graph.nodes[nodeID].kind else {
                return false
            }
            return true
        }
        let firstPick = try #require(pickNodeIDs.first)
        let secondPick = try #require(pickNodeIDs.last)
        let pivots = ReplacementQuery.build(graph: graph).compactMap { scope -> (pickNodeID: Int, targetBranchID: UInt64)? in
            guard case let .branchPivot(pickNodeID, targetBranchID) = scope else {
                return nil
            }
            return (pickNodeID, targetBranchID)
        }

        #expect(pickNodeIDs.count == 2)
        #expect(pivots.contains { $0.pickNodeID == firstPick && $0.targetBranchID == 1 } == false)
        #expect(pivots.contains { $0.pickNodeID == secondPick && $0.targetBranchID == 1 })
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

/// A pick written at one source location whose integer arm's domain is supplied by the caller, so every call shares a fingerprint.
private func sharedLocationPick(in range: ClosedRange<UInt64>) -> Generator<UInt64> {
    Gen.pick(choices: [
        (1, Gen.choose(in: range)),
        (1, Gen.just(UInt64(3))),
    ])
}
