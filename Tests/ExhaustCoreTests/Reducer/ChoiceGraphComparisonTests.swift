//
//  ChoiceGraphComparisonTests.swift
//  Exhaust
//

@testable import ExhaustCore
import Testing

// MARK: - ChoiceGraph vs CDG + BindSpanIndex Comparison Tests

@Suite("ChoiceGraph Comparison")
struct ChoiceGraphComparisonTests {
    // MARK: - Helpers

    /// Builds both ChoiceGraph and CDG + BindSpanIndex from the same tree, runs all comparison checks.
    private func validateComparison(tree: ChoiceTree) -> ChoiceGraphComparisonResult {
        let sequence = ChoiceSequence(tree)
        let bindIndex = BindSpanIndex(from: sequence)
        let cdg = ChoiceDependencyGraph.build(from: sequence, tree: tree, bindIndex: bindIndex)
        let graph = ChoiceGraph.build(from: tree)
        return ChoiceGraphComparison.validate(
            graph: graph,
            cdg: cdg,
            bindIndex: bindIndex,
            sequence: sequence
        )
    }

    // MARK: - Simple Generators

    @Test("Zip of leaves — all checks pass")
    func zipOfLeaves() {
        let tree = ChoiceTree.group([
            .choice(.unsigned(1, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
            .choice(.unsigned(2, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
            .choice(.unsigned(3, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true)),
        ])
        let result = validateComparison(tree: tree)
        #expect(result.allPassed, "Failed checks: \(result.checks.filter { $0.passed == false }.map(\.name))")
    }

    @Test("Single bind — all checks pass")
    func singleBind() {
        let inner = ChoiceTree.choice(.unsigned(42, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        let bound = ChoiceTree.choice(.unsigned(7, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        let tree = ChoiceTree.bind(inner: inner, bound: bound)
        let result = validateComparison(tree: tree)
        #expect(result.allPassed, "Failed checks: \(result.checks.filter { $0.passed == false }.map(\.name))")
    }

    @Test("Nested binds — all checks pass")
    func nestedBinds() {
        let valA = ChoiceTree.choice(.unsigned(10, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        let valB = ChoiceTree.choice(.unsigned(20, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        let valC = ChoiceTree.choice(.unsigned(30, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        let innerBind = ChoiceTree.bind(inner: valB, bound: valC)
        let outerBind = ChoiceTree.bind(inner: valA, bound: innerBind)
        let result = validateComparison(tree: outerBind)
        #expect(result.allPassed, "Failed checks: \(result.checks.filter { $0.passed == false }.map(\.name))")
    }

    @Test("Pick site with two branches — all checks pass")
    func pickSite() {
        let branchA = ChoiceTree.branch(
            siteID: 1000, weight: 1, id: 0, branchIDs: [0, 1],
            choice: .choice(.unsigned(10, .uint64), .init(validRange: 0 ... 100))
        )
        let branchB = ChoiceTree.branch(
            siteID: 1000, weight: 1, id: 1, branchIDs: [0, 1],
            choice: .choice(.unsigned(20, .uint64), .init(validRange: 0 ... 100))
        )
        let tree = ChoiceTree.group([branchA, .selected(branchB)])
        let result = validateComparison(tree: tree)
        #expect(result.allPassed, "Failed checks: \(result.checks.filter { $0.passed == false }.map(\.name))")
    }

    @Test("Sequence with elements — all checks pass")
    func sequenceWithElements() {
        let elementA = ChoiceTree.choice(.unsigned(1, .uint64), .init(validRange: 0 ... 10))
        let elementB = ChoiceTree.choice(.unsigned(2, .uint64), .init(validRange: 0 ... 10))
        let tree = ChoiceTree.sequence(
            length: 2,
            elements: [elementA, elementB],
            .init(validRange: 0 ... 5, isRangeExplicit: true)
        )
        let result = validateComparison(tree: tree)
        #expect(result.allPassed, "Failed checks: \(result.checks.filter { $0.passed == false }.map(\.name))")
    }

    @Test("getSize-bind is transparent — all checks pass")
    func getSizeBind() {
        let inner = ChoiceTree.getSize(100)
        let bound = ChoiceTree.choice(.unsigned(42, .uint64), .init(validRange: 0 ... 100))
        let tree = ChoiceTree.bind(inner: inner, bound: bound)
        let result = validateComparison(tree: tree)
        #expect(result.allPassed, "Failed checks: \(result.checks.filter { $0.passed == false }.map(\.name))")
    }

    // MARK: - Composite Generators

    @Test("Bind inside zip — all checks pass")
    func bindInsideZip() {
        let leaf = ChoiceTree.choice(.unsigned(5, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true))
        let inner = ChoiceTree.choice(.unsigned(42, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        let bound = ChoiceTree.choice(.unsigned(7, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        let tree = ChoiceTree.group([
            leaf,
            .bind(inner: inner, bound: bound),
        ])
        let result = validateComparison(tree: tree)
        #expect(result.allPassed, "Failed checks: \(result.checks.filter { $0.passed == false }.map(\.name))")
    }

    @Test("Pick inside bind — all checks pass")
    func pickInsideBind() {
        let branchA = ChoiceTree.branch(
            siteID: 2000, weight: 1, id: 0, branchIDs: [0, 1],
            choice: .choice(.unsigned(10, .uint64), .init(validRange: 0 ... 100))
        )
        let branchB = ChoiceTree.branch(
            siteID: 2000, weight: 1, id: 1, branchIDs: [0, 1],
            choice: .choice(.unsigned(20, .uint64), .init(validRange: 0 ... 100))
        )
        let pickGroup = ChoiceTree.group([branchA, .selected(branchB)])
        let inner = ChoiceTree.choice(.unsigned(1, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true))
        let tree = ChoiceTree.bind(inner: inner, bound: pickGroup)
        let result = validateComparison(tree: tree)
        #expect(result.allPassed, "Failed checks: \(result.checks.filter { $0.passed == false }.map(\.name))")
    }

    @Test("Sequence inside bind — all checks pass")
    func sequenceInsideBind() {
        let inner = ChoiceTree.choice(.unsigned(3, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true))
        let elementA = ChoiceTree.choice(.unsigned(1, .uint64), .init(validRange: 0 ... 10))
        let elementB = ChoiceTree.choice(.unsigned(2, .uint64), .init(validRange: 0 ... 10))
        let bound = ChoiceTree.sequence(
            length: 2,
            elements: [elementA, elementB],
            .init(validRange: 0 ... 5)
        )
        let tree = ChoiceTree.bind(inner: inner, bound: bound)
        let result = validateComparison(tree: tree)
        #expect(result.allPassed, "Failed checks: \(result.checks.filter { $0.passed == false }.map(\.name))")
    }

    // MARK: - Individual Check Detail Verification

    @Test("Dependency edge check reports correct counts")
    func dependencyEdgeCounts() {
        let valA = ChoiceTree.choice(.unsigned(10, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        let valB = ChoiceTree.choice(.unsigned(20, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        let valC = ChoiceTree.choice(.unsigned(30, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        let innerBind = ChoiceTree.bind(inner: valB, bound: valC)
        let outerBind = ChoiceTree.bind(inner: valA, bound: innerBind)

        let sequence = ChoiceSequence(outerBind)
        let bindIndex = BindSpanIndex(from: sequence)
        let cdg = ChoiceDependencyGraph.build(from: sequence, tree: outerBind, bindIndex: bindIndex)
        let graph = ChoiceGraph.build(from: outerBind)

        let edgeCheck = ChoiceGraphComparison.checkDependencyEdges(graph: graph, cdg: cdg)
        #expect(edgeCheck.passed)
    }

    @Test("Bind depth check reports correct values")
    func bindDepthValues() {
        let valA = ChoiceTree.choice(.unsigned(10, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        let valB = ChoiceTree.choice(.unsigned(20, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        let valC = ChoiceTree.choice(.unsigned(30, .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
        let innerBind = ChoiceTree.bind(inner: valB, bound: valC)
        let outerBind = ChoiceTree.bind(inner: valA, bound: innerBind)

        let sequence = ChoiceSequence(outerBind)
        let bindIndex = BindSpanIndex(from: sequence)
        let graph = ChoiceGraph.build(from: outerBind)

        let depthCheck = ChoiceGraphComparison.checkBindDepth(
            graph: graph,
            bindIndex: bindIndex,
            sequence: sequence
        )
        #expect(depthCheck.passed)
    }
}
