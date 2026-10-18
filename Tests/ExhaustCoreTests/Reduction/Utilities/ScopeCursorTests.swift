import Testing
@testable import ExhaustCore

@Suite("Scope cursors")
struct ScopeCursorTests {
    @Test("Buffered enumeration preserves complete leaf groups")
    func bufferedGroupsRemainComplete() throws {
        let groupedScope = ValueMinimizationScope(
            leaves: [LeafEntry(nodeID: 1), LeafEntry(nodeID: 2)],
            batchZeroEligible: true
        )
        let singleScope = ValueMinimizationScope(
            leaves: [LeafEntry(nodeID: 3)],
            batchZeroEligible: false
        )
        var cursor = BufferedScopeCursor([groupedScope, singleScope])

        #expect(cursor.peekScope?.leaves.map(\.nodeID) == [1, 2])
        let first = try #require(nextScope(from: &cursor))
        let second = try #require(nextScope(from: &cursor))

        #expect(first.leaves.map(\.nodeID) == [1, 2])
        #expect(first.batchZeroEligible)
        #expect(second.leaves.map(\.nodeID) == [3])
        #expect(second.batchZeroEligible == false)
        #expect(nextScope(from: &cursor) == nil)
        #expect(nextScope(from: &cursor) == nil)
        #expect(cursor.peekScope == nil)
    }

    @Test("Empty buffered cursors remain exhausted")
    func emptyCursorIsExhausted() {
        var cursor = BufferedScopeCursor<ValueMinimizationScope>([])
        #expect(nextScope(from: &cursor) == nil)
        #expect(nextScope(from: &cursor) == nil)
        #expect(cursor.peekScope == nil)
    }
}

// MARK: - Fixtures

private func nextScope<Cursor: ScopeCursor>(from cursor: inout Cursor) -> Cursor.Scope? {
    cursor.next()
}
