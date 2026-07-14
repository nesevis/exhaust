//
//  ConvergenceTransferTests.swift
//  Exhaust
//

import Testing
@testable import ExhaustCore

// MARK: - Convergence Transfer Tests

/// Pins the transport semantics of ``ChoiceGraphScheduler/transferConvergence(_:to:)`` across structural rebuilds.
///
/// `sequenceChild` path steps are positional sibling indices, so a mid-sequence deletion shifts every later sibling's path down by one. Without the bit-pattern guard, the shifted survivor inherits its deleted-or-shifted neighbor's convergence record (F1 in `reducer-critical-pair-catalogue.md`). These tests document what the guard drops, what it keeps, and the two deliberate exceptions: equal-value aliases (indistinguishable, still transfer) and pass-accepted leaves (exempt because their old-graph values are stale).
@Suite("Convergence transfer")
struct ConvergenceTransferTests {
    @Test("Mid-sequence deletion drops shifted records instead of aliasing")
    func midSequenceDeletionDropsShiftedRecords() throws {
        var oldGraph = sequenceGraph(values: [10, 20, 30])
        let oldLeaves = orderedLeafNodeIDs(in: oldGraph)
        oldGraph.convergenceStore[oldLeaves[0]] = record(bound: 1)
        oldGraph.convergenceStore[oldLeaves[1]] = record(bound: 2)
        oldGraph.convergenceStore[oldLeaves[2]] = record(bound: 3)

        let records = ChoiceGraphScheduler.extractAllConvergence(from: oldGraph)

        // Element 20 deleted: 30 shifts from index 2 to index 1, inheriting 20's old path.
        var newGraph = sequenceGraph(values: [10, 30])
        ChoiceGraphScheduler.transferConvergence(records, to: &newGraph)
        let newLeaves = orderedLeafNodeIDs(in: newGraph)

        // The unshifted survivor keeps its own record.
        let survivorRecord = try #require(newGraph.convergenceStore[newLeaves[0]])
        #expect(survivorRecord.bound == 1)

        // The shifted survivor must not inherit its neighbor's floor.
        #expect(newGraph.convergenceStore[newLeaves[1]] == nil)
    }

    @Test("Equal-value alias still transfers as the accepted residual")
    func equalValueAliasTransfers() throws {
        var oldGraph = sequenceGraph(values: [10, 10, 30])
        let oldLeaves = orderedLeafNodeIDs(in: oldGraph)
        oldGraph.convergenceStore[oldLeaves[0]] = record(bound: 1)
        oldGraph.convergenceStore[oldLeaves[1]] = record(bound: 2)
        oldGraph.convergenceStore[oldLeaves[2]] = record(bound: 3)

        let records = ChoiceGraphScheduler.extractAllConvergence(from: oldGraph)

        // The first element is deleted. The surviving 10 (logically element 1, bound 2) shifts into index 0, where the deleted twin's record (bound 1) sits with a matching value. No per-element identity survives sibling mutation, so the alias transfers.
        var newGraph = sequenceGraph(values: [10, 30])
        ChoiceGraphScheduler.transferConvergence(records, to: &newGraph)
        let newLeaves = orderedLeafNodeIDs(in: newGraph)

        let aliasedRecord = try #require(newGraph.convergenceStore[newLeaves[0]])
        #expect(aliasedRecord.bound == 1)

        // The shifted 30 finds the second 10's record at its path. Value mismatch, dropped.
        #expect(newGraph.convergenceStore[newLeaves[1]] == nil)
    }

    @Test("Exempt leaves transfer despite value mismatch")
    func exemptLeavesTransferDespiteValueMismatch() throws {
        // A leaf that accepted a change in the pass triggering the rebuild holds a stale value in the old graph (reshape and stateful passes skip the in-place apply): old graph says 10, the accepted value is 5.
        var oldGraph = sequenceGraph(values: [10, 20])
        let oldLeaves = orderedLeafNodeIDs(in: oldGraph)
        oldGraph.convergenceStore[oldLeaves[0]] = record(bound: 5)

        let newGraphValues: [UInt64] = [5, 20]

        // Without the exemption the fresh record is dropped as a mismatch.
        let guardedRecords = ChoiceGraphScheduler.extractAllConvergence(from: oldGraph)
        var guardedGraph = sequenceGraph(values: newGraphValues)
        ChoiceGraphScheduler.transferConvergence(guardedRecords, to: &guardedGraph)
        #expect(guardedGraph.convergenceStore[orderedLeafNodeIDs(in: guardedGraph)[0]] == nil)

        // With the exemption it transfers on path and type tag alone.
        let exemptRecords = ChoiceGraphScheduler.extractAllConvergence(
            from: oldGraph,
            valueGuardExemptNodeIDs: [oldLeaves[0]]
        )
        var exemptGraph = sequenceGraph(values: newGraphValues)
        ChoiceGraphScheduler.transferConvergence(exemptRecords, to: &exemptGraph)

        let transferredRecord = try #require(exemptGraph.convergenceStore[orderedLeafNodeIDs(in: exemptGraph)[0]])
        #expect(transferredRecord.bound == 5)
    }
}

// MARK: - Test helpers

private func sequenceGraph(values: [UInt64]) -> ChoiceGraph {
    let elements = values.map { value in
        ChoiceTree.choice(ChoiceValue(value, tag: .uint64), .init(validRange: 0 ... 100, isRangeExplicit: true))
    }
    let tree = ChoiceTree.sequence(
        elements: elements,
        metadata: .init(validRange: 0 ... 10, isRangeExplicit: true)
    )
    return ChoiceGraph.build(from: tree)
}

private func orderedLeafNodeIDs(in graph: ChoiceGraph) -> [Int] {
    graph.leafNodes
        .filter { graph.nodes[$0].positionRange != nil }
        .sorted { lhs, rhs in
            graph.nodes[lhs].positionRange!.lowerBound < graph.nodes[rhs].positionRange!.lowerBound
        }
}

private func record(bound: UInt64) -> ConvergedOrigin {
    ConvergedOrigin(
        bound: bound,
        signal: .monotoneConvergence,
        configuration: .binarySearchSemanticSimplest,
        cycle: 0
    )
}
