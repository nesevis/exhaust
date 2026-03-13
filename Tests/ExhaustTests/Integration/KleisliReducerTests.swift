//
//  KleisliReducerTests.swift
//  Exhaust
//
//  Tests for the KleisliReducer (principled test case reduction via cyclic coordinate descent).
//

import Testing
@testable import ExhaustCore
@testable import Exhaust

// MARK: - TacticLattice Unit Tests

@Suite("TacticLattice")
struct TacticLatticeTests {
    @Test("Traversal yields all nodes in order")
    func traversalOrder() {
        let lattice = TacticLattice<String>(nodes: [
            .init(tactic: "A", dominates: [1, 2]),
            .init(tactic: "B", dominates: [2]),
            .init(tactic: "C", dominates: []),
        ])

        var traversal = lattice.orderedTraversal()
        #expect(traversal.next() == "A")
        #expect(traversal.next() == "B")
        #expect(traversal.next() == "C")
        #expect(traversal.next() == nil)
    }

    @Test("Pruning after success skips dominated nodes")
    func pruningAfterSuccess() {
        let lattice = TacticLattice<String>(nodes: [
            .init(tactic: "A", dominates: [1, 2]),
            .init(tactic: "B", dominates: []),
            .init(tactic: "C", dominates: []),
        ])

        var traversal = lattice.orderedTraversal()
        #expect(traversal.next() == "A")
        traversal.markSucceeded()
        // B and C should be pruned
        #expect(traversal.next() == nil)
    }

    @Test("Partial pruning leaves incomparable nodes")
    func partialPruning() {
        // A dominates B but not C
        let lattice = TacticLattice<String>(nodes: [
            .init(tactic: "A", dominates: [1]),
            .init(tactic: "B", dominates: []),
            .init(tactic: "C", dominates: []),
        ])

        var traversal = lattice.orderedTraversal()
        #expect(traversal.next() == "A")
        traversal.markSucceeded()
        // B pruned, C still available
        #expect(traversal.next() == "C")
        #expect(traversal.next() == nil)
    }

    @Test("Reset clears pruning state")
    func resetTraversal() {
        let lattice = TacticLattice<String>(nodes: [
            .init(tactic: "A", dominates: [1]),
            .init(tactic: "B", dominates: []),
        ])

        var traversal = lattice.orderedTraversal()
        _ = traversal.next() // A
        traversal.markSucceeded()
        #expect(traversal.next() == nil) // B pruned

        traversal.reset()
        #expect(traversal.next() == "A")
        #expect(traversal.next() == "B") // No longer pruned
    }

    @Test("Incomparable nodes are both visited regardless of other pruning")
    func incomparableNodesVisited() {
        // A dominates C, B dominates C, but A and B are incomparable
        let lattice = TacticLattice<String>(nodes: [
            .init(tactic: "A", dominates: [2]),
            .init(tactic: "B", dominates: [2]),
            .init(tactic: "C", dominates: []),
        ])

        var traversal = lattice.orderedTraversal()
        #expect(traversal.next() == "A")
        // Don't mark succeeded — A didn't help
        #expect(traversal.next() == "B")
        traversal.markSucceeded()
        // C dominated by B, should be pruned
        #expect(traversal.next() == nil)
    }

    @Test("Empty lattice produces empty traversal")
    func emptyLattice() {
        let lattice = TacticLattice<String>(nodes: [])
        var traversal = lattice.orderedTraversal()
        #expect(traversal.next() == nil)
    }
}

// MARK: - KleisliReducer Integration Tests

@Suite("KleisliReducer")
struct KleisliReducerIntegrationTests {
    @Test("Non-bind generator produces same result as existing reducer")
    func nonBindEquivalence() throws {
        let gen = Gen.choose(in: UInt64(0) ... 1000)

        var iterator = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: 42)
        let (value, tree) = try #require(try iterator.next())
        try #require(value > 5)

        let kleisliResult = try #require(
            try Interpreters.kleisliReduce(gen: gen, tree: tree, config: .fast) { $0 < 5 }
        )

        #expect(kleisliResult.1 == 5)
    }

    @Test("Bind-dependent array length shrinks correctly")
    func bindDependentShrink() throws {
        let gen = #gen(.int(in: 1 ... 10))
            .bound(
                forward: { n in Gen.int(in: 0 ... 100).array(length: UInt64(n)) },
                backward: { (arr: [Int]) in arr.count }
            )

        ExhaustLog.setConfiguration(.init(isEnabled: true, minimumLevel: .info, categoryMinimumLevels: [.reducer: .debug], format: .human))
        var iterator = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: 42)
        var failingTree: ChoiceTree?
        while let (value, tree) = try iterator.next() {
            if value.count > 2 {
                failingTree = tree
                break
            }
        }

        let tree = try #require(failingTree)
        #expect(tree.containsBind)

        let (_, shrunk) = try #require(
            try Interpreters.kleisliReduce(gen: gen, tree: tree, config: .fast) { $0.count <= 2 }
        )

        #expect(shrunk == [0, 0, 0])
    }

    @Test("Non-bind degenerate case: maxBindDepth == 0, single coordinate")
    func nonBindDegenerateCase() throws {
        // Int array with sum > 10. Minimal: [11] or similar.
        let gen = Gen.int(in: 0 ... 100).array(length: 1 ... 5)

        var iterator = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: 42)
        var failingTree: ChoiceTree?
        while let (value, tree) = try iterator.next() {
            if value.reduce(0, +) > 10 {
                failingTree = tree
                break
            }
        }

        let tree = try #require(failingTree)
        #expect(tree.containsBind == false)

        let (_, shrunk) = try #require(
            try Interpreters.kleisliReduce(gen: gen, tree: tree, config: .fast) {
                $0.reduce(0, +) <= 10
            }
        )

        #expect(shrunk.reduce(0, +) > 10)
        // Should be reasonably minimal
        #expect(shrunk.count <= 2)
    }

    @Test("Reducer terminates and returns a result")
    func termination() throws {
        let gen = Gen.int(in: 0 ... 1000)
        var iterator = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: 42)
        let (value, tree) = try #require(try iterator.next())
        try #require(value > 50)

        let result = try Interpreters.kleisliReduce(gen: gen, tree: tree, config: .fast) { $0 <= 50 }
        #expect(result != nil)
        if let (_, shrunk) = result {
            print()
            #expect(shrunk == 51)
        }
    }
}

// MARK: - BindSpanIndex.spansByDepth Tests

@Suite("BindSpanIndex.spansByDepth")
struct SpansByDepthTests {
    @Test("Non-bind spans all land at depth 0")
    func nonBindSpans() {
        let tree = ChoiceTree.group([
            .choice(.unsigned(1, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
            .choice(.unsigned(2, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
        ])
        let sequence = ChoiceSequence.flatten(tree)
        let index = BindSpanIndex(from: sequence)
        let spans = ChoiceSequence.extractAllValueSpans(from: sequence)

        let byDepth = index.spansByDepth(spans)
        #expect(byDepth.count == 1)
        #expect(byDepth[0].count == spans.count)
    }

    @Test("Bind-dependent spans are grouped by depth")
    func bindSpans() {
        let valA = ChoiceTree.choice(.unsigned(10, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        let valB = ChoiceTree.choice(.unsigned(20, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        let tree = ChoiceTree.bind(inner: valA, bound: valB)

        let sequence = ChoiceSequence.flatten(tree)
        let index = BindSpanIndex(from: sequence)
        let spans = ChoiceSequence.extractAllValueSpans(from: sequence)

        let byDepth = index.spansByDepth(spans)
        #expect(byDepth.count == 2)
        // valA (inner) should be at depth 0, valB (bound) should be at depth 1
        #expect(byDepth[0].count == 1) // inner
        #expect(byDepth[1].count == 1) // bound
    }
}
