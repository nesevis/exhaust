//
//  BonsaiReducerTests.swift
//  Exhaust
//

import ExhaustCore
import Testing

// MARK: - BonsaiReducer Integration Tests

@Suite("BonsaiReducer")
struct BonsaiReducerIntegrationTests {
    @Test("Non-bind generator produces same result as existing reducer")
    func nonBindEquivalence() throws {
        let gen = Gen.choose(in: UInt64(0) ... 1000)

        var iterator = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: 42)
        let (value, tree) = try #require(try iterator.next())
        try #require(value > 5)

        let bonsaiResult = try #require(
            try Interpreters.bonsaiReduce(gen: gen, tree: tree, config: .fast) { $0 < 5 }
        )

        #expect(bonsaiResult.1 == 5)
    }

    @Test("Bind-dependent array length shrinks correctly")
    func bindDependentShrink() throws {
        let gen: ReflectiveGenerator<[Int]> = Gen.choose(in: 1 ... 10 as ClosedRange<Int>)._bound(
            forward: { n in
                Gen.arrayOf(Gen.choose(in: 0 ... 100 as ClosedRange<Int>), exactly: UInt64(n))
            },
            backward: { (arr: [Int]) in
                arr.count
            }
        )

        try ExhaustLog.withConfiguration(.init(minimumLevel: .info, categoryMinimumLevels: [.reducer: .debug], format: .keyValue)) {
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
                try Interpreters.bonsaiReduce(gen: gen, tree: tree, config: .fast) { $0.count <= 2 }
            )

            #expect(shrunk == [0, 0, 0])
        }
    }

    @Test("Non-bind degenerate case: maxBindDepth == 0, single coordinate")
    func nonBindDegenerateCase() throws {
        // Int array with sum > 10. Minimal: [11] or similar.
        let gen = Gen.arrayOf(Gen.choose(in: 0 ... 100 as ClosedRange<Int>), within: 1 ... 5)

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
            try Interpreters.bonsaiReduce(gen: gen, tree: tree, config: .fast) {
                $0.reduce(0, +) <= 10
            }
        )

        #expect(shrunk.reduce(0, +) > 10)
        // Should be reasonably minimal
        #expect(shrunk.count <= 2)
    }

    @Test("Reducer terminates and returns a result")
    func termination() throws {
        let gen = Gen.choose(in: 0 ... 1000 as ClosedRange<Int>)
        var iterator = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: 42)
        let (value, tree) = try #require(try iterator.next())
        try #require(value > 50)

        let result = try Interpreters.bonsaiReduce(gen: gen, tree: tree, config: .fast) { $0 <= 50 }
        #expect(result != nil)
        if let (_, shrunk) = result {
            print()
            #expect(shrunk == 51)
        }
    }

    @Test("Bind-dependent shrink output still fails the property")
    func bindShrinkOutputFailsProperty() throws {
        // A bind generator where bound content depends on the inner value:
        // inner picks a length, bound generates that many elements.
        let gen: ReflectiveGenerator<[Int]> = Gen.choose(in: 1 ... 5 as ClosedRange<Int>)._bound(
            forward: { n in
                Gen.arrayOf(Gen.choose(in: 0 ... 50 as ClosedRange<Int>), exactly: UInt64(n))
            },
            backward: { (arr: [Int]) in
                arr.count
            }
        )

        let property: ([Int]) -> Bool = { $0.count < 3 || $0.allSatisfy { $0 <= 10 } }

        var iterator = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: 99)
        var failingTree: ChoiceTree?
        while let (value, tree) = try iterator.next() {
            if property(value) == false {
                failingTree = tree
                break
            }
        }

        let tree = try #require(failingTree)
        let (shrunkSequence, shrunkOutput) = try #require(
            try Interpreters.bonsaiReduce(gen: gen, tree: tree, config: .fast, property: property)
        )

        // The shrunk output must still violate the property
        #expect(property(shrunkOutput) == false)

        // The shrunk sequence must be valid (materializable)
        guard case let .success(replayedOutput, _, _) = Materializer.materialize(gen, prefix: shrunkSequence, mode: .exact, fallbackTree: tree) else {
            Issue.record("Expected .success")
            return
        }
        // Replayed output must also violate the property
        #expect(property(replayedOutput) == false)
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
