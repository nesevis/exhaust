//
//  BindAwareReducerTests.swift
//  Exhaust
//
//  Tests for bind-aware reducer passes (Opportunity 2, Phases 2-3).
//  Verifies BindSpanIndex correctness, bind-dependent shrinking via
//  GuidedMaterializer routing, and non-regression for bind-free generators.
//

import Testing
@testable import ExhaustCore

// MARK: - BindSpanIndex Unit Tests

@Suite("BindSpanIndex")
struct BindSpanIndexTests {
    @Test("Simple bind tree produces one region with correct ranges")
    func simpleBindRegion() {
        let inner = ChoiceTree.choice(.unsigned(42, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        let bound = ChoiceTree.choice(.unsigned(7, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        let tree = ChoiceTree.bind(inner: inner, bound: bound)

        let sequence = ChoiceSequence.flatten(tree)
        // Expected: .bind(true), value(42), value(7), .bind(false)
        let index = BindSpanIndex(from: sequence)

        #expect(index.isEmpty == false)
        #expect(index.regions.count == 1)

        let region = index.regions[0]
        #expect(region.bindSpanRange == 0 ... 3)
        #expect(region.innerRange.contains(1))
        #expect(region.boundRange.contains(2))
    }

    @Test("Empty sequence produces empty index")
    func emptySequence() {
        let index = BindSpanIndex(from: ChoiceSequence())
        #expect(index.isEmpty)
        #expect(index.regions.isEmpty)
    }

    @Test("Sequence without binds produces empty index")
    func noBinds() {
        let tree = ChoiceTree.group([
            .choice(.unsigned(1, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
            .choice(.unsigned(2, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
        ])
        let sequence = ChoiceSequence.flatten(tree)
        let index = BindSpanIndex(from: sequence)

        #expect(index.isEmpty)
    }

    @Test("bindRegionForInnerIndex returns region for inner position")
    func innerIndexLookup() {
        let inner = ChoiceTree.choice(.unsigned(42, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        let bound = ChoiceTree.choice(.unsigned(7, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        let tree = ChoiceTree.bind(inner: inner, bound: bound)
        let sequence = ChoiceSequence.flatten(tree)
        let index = BindSpanIndex(from: sequence)

        // Index 1 is the inner value
        let region = index.bindRegionForInnerIndex(1)
        #expect(region != nil)
    }

    @Test("bindRegionForInnerIndex returns nil for bound position")
    func boundIndexNotInner() {
        let inner = ChoiceTree.choice(.unsigned(42, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        let bound = ChoiceTree.choice(.unsigned(7, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        let tree = ChoiceTree.bind(inner: inner, bound: bound)
        let sequence = ChoiceSequence.flatten(tree)
        let index = BindSpanIndex(from: sequence)

        // Index 2 is the bound value — not in any inner range
        let region = index.bindRegionForInnerIndex(2)
        #expect(region == nil)
    }

    @Test("isInBoundSubtree correctly identifies bound positions")
    func boundSubtreeCheck() {
        let inner = ChoiceTree.choice(.unsigned(42, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        let bound = ChoiceTree.choice(.unsigned(7, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        let tree = ChoiceTree.bind(inner: inner, bound: bound)
        let sequence = ChoiceSequence.flatten(tree)
        let index = BindSpanIndex(from: sequence)

        #expect(index.isInBoundSubtree(0) == false) // .bind(true) marker
        #expect(index.isInBoundSubtree(1) == false) // inner value
        #expect(index.isInBoundSubtree(2) == true)  // bound value
        #expect(index.isInBoundSubtree(3) == false) // .bind(false) marker
    }

    @Test("Bind inside a group is indexed correctly")
    func bindInsideGroup() {
        let inner = ChoiceTree.choice(.unsigned(10, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        let bound = ChoiceTree.choice(.unsigned(20, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        let bindTree = ChoiceTree.bind(inner: inner, bound: bound)
        let sibling = ChoiceTree.choice(.unsigned(99, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        let tree = ChoiceTree.group([bindTree, sibling])

        let sequence = ChoiceSequence.flatten(tree)
        let index = BindSpanIndex(from: sequence)

        #expect(index.isEmpty == false)
        #expect(index.regions.count == 1)

        // The sibling value should not be in any bound subtree
        let siblingIdx = sequence.count - 2 // last value before group close
        #expect(index.isInBoundSubtree(siblingIdx) == false)
    }

    @Test("Bind with grouped bound subtree has correct children")
    func bindWithGroupedBound() {
        // Inner: single value. Bound: group of two values.
        let inner = ChoiceTree.choice(.unsigned(5, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true))
        let boundChild1 = ChoiceTree.choice(.unsigned(10, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        let boundChild2 = ChoiceTree.choice(.unsigned(20, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        let bound = ChoiceTree.group([boundChild1, boundChild2])
        let tree = ChoiceTree.bind(inner: inner, bound: bound)

        let sequence = ChoiceSequence.flatten(tree)
        let index = BindSpanIndex(from: sequence)

        #expect(index.isEmpty == false)
        #expect(index.regions.count == 1)

        let region = index.regions[0]
        // Inner is a bare value, bound is a group container
        #expect(region.innerRange.count == 1)
        #expect(region.boundRange.count >= 3) // group(true), value, value, group(false)

        // Values inside the bound group should be identified as bound
        for idx in region.boundRange {
            #expect(index.isInBoundSubtree(idx))
        }
    }
}

    @Test("Nested binds produce two regions with correct nesting")
    func nestedBinds() {
        // Outer bind: inner = value A, bound = inner bind
        // Inner bind: inner = value B, bound = value C
        // Flattened: { A { B C } }
        let valA = ChoiceTree.choice(.unsigned(10, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        let valB = ChoiceTree.choice(.unsigned(20, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        let valC = ChoiceTree.choice(.unsigned(30, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        let innerBind = ChoiceTree.bind(inner: valB, bound: valC)
        let outerBind = ChoiceTree.bind(inner: valA, bound: innerBind)

        let sequence = ChoiceSequence.flatten(outerBind)
        // Expected: {outer A {inner B C }inner }outer
        // Indices:   0     1  2      3 4  5      6
        let index = BindSpanIndex(from: sequence)

        #expect(index.regions.count == 2)

        // Find outer and inner regions by span size
        let outer = index.regions.first { $0.bindSpanRange.count > 4 }
        let inner = index.regions.first { $0.bindSpanRange.count <= 4 }
        #expect(outer != nil)
        #expect(inner != nil)

        // Outer bind: inner is A (bare value), bound is the inner bind container
        #expect(outer!.innerRange.count == 1)
        #expect(outer!.boundRange.count > 1) // covers the entire inner bind span

        // Inner bind: inner is B, bound is C
        #expect(inner!.innerRange.count == 1)
        #expect(inner!.boundRange.count == 1)

        // A (outer inner) is not in any bound subtree
        let aIdx = outer!.innerRange.lowerBound
        #expect(index.isInBoundSubtree(aIdx) == false)
        #expect(index.bindRegionForInnerIndex(aIdx) != nil)

        // B (inner bind's inner) IS in the outer bound subtree
        let bIdx = inner!.innerRange.lowerBound
        #expect(index.isInBoundSubtree(bIdx) == true)
        // But it's also an inner index for the inner bind
        #expect(index.bindRegionForInnerIndex(bIdx) != nil)

        // C (inner bind's bound) is in both the outer bound and inner bound subtrees
        let cIdx = inner!.boundRange.lowerBound
        #expect(index.isInBoundSubtree(cIdx) == true)
        #expect(index.bindRegionForInnerIndex(cIdx) == nil) // C is not any bind's inner
    }

// MARK: - Bind-Aware Reduction Integration Tests

@Suite("Bind-Aware Reduction")
struct BindAwareReductionTests {
    @Test("Bind-dependent generator shrinks inner value correctly")
    func bindDependentShrink() throws {
        // Inner: pick n from 1...10.
        // Bound: array of n elements, each from 0...100.
        // Property: array length <= 2 (fails when n >= 3).
        // Minimal: n=3, array has 3 elements.
        let gen: ReflectiveGenerator<[Int]> = Gen.liftF(.transform(
            kind: .bind(
                forward: { innerValue -> ReflectiveGenerator<Any> in
                    let n = innerValue as! Int
                    return Gen.arrayOf(
                        Gen.choose(in: 0 ... 100 as ClosedRange<Int>),
                        exactly: UInt64(max(0, n))
                    ).erase()
                },
                backward: { finalOutput -> Any in
                    (finalOutput as! [Int]).count
                },
                inputType: "Int",
                outputType: "[Int]"
            ),
            inner: Gen.choose(in: 1 ... 10 as ClosedRange<Int>).erase()
        ))

        // Generate until we find a value with count > 2
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

        let property: ([Int]) -> Bool = { $0.count <= 2 }
        let (_, shrunk) = try #require(
            try Interpreters.reduce(gen: gen, tree: tree, config: .fast, property: property)
        )

        // Minimal counterexample: array with exactly 3 elements
        #expect(shrunk.count == 3)
    }

    @Test("Bind-dependent range generator shrinks correctly")
    func bindDependentRangeShrink() throws {
        // Inner: pick n from 0...100.
        // Bound: pick m from 0...max(1, n). Output is m (Int).
        // Property: m < 5 (fails when m >= 5).
        // When the reducer shrinks inner n, the bound range 0...n changes,
        // so the reducer must re-derive m via GuidedMaterializer.
        let gen: ReflectiveGenerator<Int> = Gen.liftF(.transform(
            kind: .bind(
                forward: { innerValue -> ReflectiveGenerator<Any> in
                    let n = innerValue as! Int
                    return Gen.choose(in: 0 ... max(1, n) as ClosedRange<Int>).erase()
                },
                backward: { finalOutput -> Any in
                    finalOutput as! Int
                },
                inputType: "Int",
                outputType: "Int"
            ),
            inner: Gen.choose(in: 0 ... 100 as ClosedRange<Int>).erase()
        ))

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

        let property: (Int) -> Bool = { $0 < 5 }
        let (_, shrunk) = try #require(
            try Interpreters.reduce(gen: gen, tree: tree, config: .fast, property: property)
        )

        // The shrunk value must still fail the property (>= 5) and be significantly
        // smaller than the original. The exact minimum depends on PRNG behavior when
        // GuidedMaterializer re-derives the bound value.
        #expect(shrunk >= 5)
        #expect(shrunk <= 10)
    }

    @Test("Non-bind generator is unaffected by bind-aware infrastructure")
    func nonBindRegression() throws {
        // Simple unsigned integer — no binds involved.
        // This verifies zero overhead / no behavior change.
        let gen = Gen.choose(in: UInt64(0) ... 1000)

        var iterator = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: 42)
        let (value, tree) = try #require(try iterator.next())
        try #require(value > 5)

        #expect(tree.containsBind == false)

        let property: (UInt64) -> Bool = { $0 < 5 }
        let (_, shrunk) = try #require(
            try Interpreters.reduce(gen: gen, tree: tree, config: .fast, property: property)
        )

        #expect(shrunk == 5)
    }
}

// MARK: - materializeCandidate Tests

@Suite("materializeCandidate")
struct MaterializeCandidateTests {
    @Test("Falls through to standard materialize when bindIndex is nil")
    func nilBindIndex() throws {
        let gen = Gen.choose(in: UInt64(0) ... 100)
        var iterator = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: 42)
        let (_, tree) = try #require(try iterator.next())
        let sequence = ChoiceSequence.flatten(tree)

        let result = try ReducerStrategies.materializeCandidate(
            gen, tree: tree, candidate: sequence, bindIndex: nil, mutatedIndex: 0
        )
        #expect(result != nil)
    }

    @Test("Falls through to standard materialize when no bind regions exist")
    func emptyBindIndex() throws {
        let gen = Gen.choose(in: UInt64(0) ... 100)
        var iterator = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: 42)
        let (_, tree) = try #require(try iterator.next())
        let sequence = ChoiceSequence.flatten(tree)
        let emptyIndex = BindSpanIndex(from: sequence)

        let result = try ReducerStrategies.materializeCandidate(
            gen, tree: tree, candidate: sequence, bindIndex: emptyIndex, mutatedIndex: 0
        )
        #expect(result != nil)
    }

    @Test("Routes through GuidedMaterializer for inner-range mutation")
    func guidedMaterializerRouting() throws {
        // Use a bind generator where bound produces actual value entries
        let gen: ReflectiveGenerator<Int> = Gen.liftF(.transform(
            kind: .bind(
                forward: { innerValue -> ReflectiveGenerator<Any> in
                    let n = innerValue as! Int
                    return Gen.choose(in: 0 ... max(1, n) as ClosedRange<Int>).erase()
                },
                backward: { finalOutput -> Any in
                    finalOutput as! Int
                },
                inputType: "Int",
                outputType: "Int"
            ),
            inner: Gen.choose(in: 0 ... 100 as ClosedRange<Int>).erase()
        ))

        var iterator = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: 42)
        let (_, genTree) = try #require(try iterator.next())
        let genSequence = ChoiceSequence.flatten(genTree)
        let genBindIndex = BindSpanIndex(from: genSequence)

        // Verify bind regions exist and materializeCandidate produces a result
        #expect(genBindIndex.isEmpty == false)
        let genInnerIdx = genBindIndex.regions[0].innerRange.lowerBound
        let result = try ReducerStrategies.materializeCandidate(
            gen, tree: genTree, candidate: genSequence, bindIndex: genBindIndex, mutatedIndex: genInnerIdx
        )
        #expect(result != nil)
    }
}

// MARK: - Helpers

private func generate<Output>(
    _ gen: ReflectiveGenerator<Output>,
    seed: UInt64 = 42,
) throws -> (value: Output, tree: ChoiceTree) {
    var iter = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: seed)
    return try #require(try iter.prefix(1).last)
}
