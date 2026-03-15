//
//  BindAwareReducerTests.swift
//  Exhaust
//
//  Tests for bind-aware reducer passes (Opportunity 2, Phases 2-3).
//  Verifies BindSpanIndex correctness, bind-dependent shrinking via
//  GuidedMaterializer routing, and non-regression for bind-free generators.
//

import Testing
@testable import Exhaust
import ExhaustCore

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

        let siblingIdx = sequence.count - 2
        #expect(index.isInBoundSubtree(siblingIdx) == false)
    }

    @Test("Bind with grouped bound subtree has correct children")
    func bindWithGroupedBound() {
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
        #expect(region.innerRange.count == 1)
        #expect(region.boundRange.count >= 3)

        for idx in region.boundRange {
            #expect(index.isInBoundSubtree(idx))
        }
    }

    @Test("Nested binds produce two regions with correct nesting")
    func nestedBinds() {
        // Outer bind: inner = A, bound = inner bind { B, C }
        // Flattened: { A { B C } }
        let valA = ChoiceTree.choice(.unsigned(10, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        let valB = ChoiceTree.choice(.unsigned(20, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        let valC = ChoiceTree.choice(.unsigned(30, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        let innerBind = ChoiceTree.bind(inner: valB, bound: valC)
        let outerBind = ChoiceTree.bind(inner: valA, bound: innerBind)

        let sequence = ChoiceSequence.flatten(outerBind)
        let index = BindSpanIndex(from: sequence)

        #expect(index.regions.count == 2)

        let outer = index.regions.first { $0.bindSpanRange.count > 4 }
        let inner = index.regions.first { $0.bindSpanRange.count <= 4 }
        #expect(outer != nil)
        #expect(inner != nil)

        #expect(outer!.innerRange.count == 1)
        #expect(outer!.boundRange.count > 1)

        #expect(inner!.innerRange.count == 1)
        #expect(inner!.boundRange.count == 1)

        // A (outer inner) — not in any bound subtree
        let aIdx = outer!.innerRange.lowerBound
        #expect(index.isInBoundSubtree(aIdx) == false)
        #expect(index.bindRegionForInnerIndex(aIdx) != nil)

        // B (inner bind's inner) — in outer's bound subtree, but also an inner
        let bIdx = inner!.innerRange.lowerBound
        #expect(index.isInBoundSubtree(bIdx) == true)
        #expect(index.bindRegionForInnerIndex(bIdx) != nil)

        // C (inner bind's bound) — in both bound subtrees, not any bind's inner
        let cIdx = inner!.boundRange.lowerBound
        #expect(index.isInBoundSubtree(cIdx) == true)
        #expect(index.bindRegionForInnerIndex(cIdx) == nil)
    }
}

// MARK: - Bind-Aware Reduction Integration Tests

@Suite("Bind-Aware Reduction")
struct BindAwareReductionTests {
    @Test("Bind-dependent array length shrinks correctly")
    func bindDependentShrink() throws {
        // Property: array.count <= 2 (fails when n >= 3). Minimal: n = 3.
        let gen = #gen(.int(in: 1 ... 10))
            .bound(
                forward: { n in Gen.int(in: 0 ... 100).array(length: UInt64(n)) },
                backward: { (arr: [Int]) in arr.count }
            )

        let output = #exhaust(gen, .suppressIssueReporting, .replay(42)) { arr in
            arr.count <= 2
        }

        #expect(output == [0, 0, 0])
    }

    @Test("Bind-dependent range shrinks correctly")
    func bindDependentRangeShrink() throws {
        // .int(in: 0...100).bound { n in .int(in: 0...max(1, n)) }
        // Property: m < 5 (fails when m >= 5).
        let gen = #gen(.int(in: 0 ... 100))
            .bound(
                forward: { n in Gen.int(in: 0 ... max(1, n)) },
                backward: { (m: Int) in m }
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
            try Interpreters.reduce(gen: gen, tree: tree, config: .fast) { $0 < 5 }
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
            try Interpreters.reduce(gen: gen, tree: tree, config: .fast) { $0 < 5 }
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
        let gen = #gen(.int(in: 0 ... 100))
            .bound(
                forward: { n in Gen.int(in: 0 ... max(1, n)) },
                backward: { (m: Int) in m }
            )

        var iterator = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: 42)
        let (_, genTree) = try #require(try iterator.next())
        let genSequence = ChoiceSequence.flatten(genTree)
        let genBindIndex = BindSpanIndex(from: genSequence)

        #expect(genBindIndex.isEmpty == false)
        let genInnerIdx = genBindIndex.regions[0].innerRange.lowerBound
        let result = try ReducerStrategies.materializeCandidate(
            gen, tree: genTree, candidate: genSequence, bindIndex: genBindIndex, mutatedIndex: genInnerIdx
        )
        #expect(result != nil)
    }
}
