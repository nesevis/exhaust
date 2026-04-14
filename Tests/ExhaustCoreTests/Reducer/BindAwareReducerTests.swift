//
//  BindAwareReducerTests.swift
//  Exhaust
//
//  Tests for bind-aware reducer passes (Opportunity 2, Phases 2-3).
//  Verifies bind-dependent shrinking via GuidedMaterializer routing and
//  non-regression for bind-free generators.
//

import ExhaustCore
import Testing

// MARK: - Bind-Aware Reduction Integration Tests

@Suite("Bind-Aware Reduction")
struct BindAwareReductionTests {
    @Test("Bind-dependent array length shrinks correctly")
    func bindDependentShrink() throws {
        // Property: array.count <= 2 (fails when n >= 3). Minimal: n = 3.
        let gen: ReflectiveGenerator<[Int]> = Gen.choose(in: 1 ... 10 as ClosedRange<Int>)._bound(
            forward: { n in
                Gen.arrayOf(Gen.choose(in: 0 ... 100 as ClosedRange<Int>), exactly: UInt64(n))
            },
            backward: { (arr: [Int]) in
                arr.count
            }
        )

        // Find a failing value, then reduce
        var iterator = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: 42)
        var failingTree: ChoiceTree?
        while let (value, tree) = try iterator.next() {
            if (value.count <= 2) == false {
                failingTree = tree
                break
            }
        }

        let tree = try #require(failingTree)
        let (_, output) = try #require(
            try Interpreters.choiceGraphReduce(gen: gen, tree: tree, config: .fast) { $0.count <= 2 }
        )

        #expect(output == [0, 0, 0])
    }

    @Test("Bind-dependent range shrinks correctly")
    func bindDependentRangeShrink() throws {
        // .int(in: 0...100).bound { n in .int(in: 0...max(1, n)) }
        // Property: m < 5 (fails when m >= 5).
        let gen: ReflectiveGenerator<Int> = Gen.choose(in: 0 ... 100 as ClosedRange<Int>)._bound(
            forward: { n in
                Gen.choose(in: 0 ... max(1, n) as ClosedRange<Int>)
            },
            backward: { (m: Int) in
                m
            }
        )

        var iterator = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: 42)
        var failingTree: ChoiceTree?
        while let (value, tree) = try iterator.next() {
            if value >= 5 {
                failingTree = tree
                break
            }
        }

        let tree = try #require(failingTree)
        #expect(tree.containsBind)

        let (_, shrunk) = try #require(
            try Interpreters.choiceGraphReduce(gen: gen, tree: tree, config: .fast) { $0 < 5 }
        )

        #expect(shrunk >= 5)
        #expect(shrunk <= 10)
    }

    @Test("Non-bind generator is unaffected by bind-aware infrastructure")
    func nonBindRegression() throws {
        let gen = Gen.choose(in: UInt64(0) ... 1000)

        var iterator = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: 42)
        let (value, tree) = try #require(try iterator.next())
        try #require(value > 5)

        #expect(tree.containsBind == false)

        let (_, shrunk) = try #require(
            try Interpreters.choiceGraphReduce(gen: gen, tree: tree, config: .fast) { $0 < 5 }
        )

        #expect(shrunk == 5)
    }
}
