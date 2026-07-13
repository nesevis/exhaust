import ExecuteFixture
import Testing

@Suite("HandleTable reproducer smoke tests")
struct HandleTableSmokeTests {
    // MARK: - Fault E (stale write after multi-entry compaction)

    @Test("Fault E fires on a stale write after a compact that relocated two entries (registry minimal)")
    func faultEMinimal() throws {
        var table = HandleTable()
        guard let first = table.create(), let second = table.create(), let third = table.create() else {
            Issue.record("three creates on an empty table must succeed")
            return
        }
        table.destroy(handle: first)
        table.compact()
        _ = third
        #expect(throws: HandleTableError.corruption) {
            try table.write(handle: second, value: 5)
        }
    }

    @Test("Fault E fires through either relocated handle")
    func faultEFiresThroughEitherRelocatedHandle() throws {
        var table = HandleTable()
        guard let first = table.create(), let second = table.create(), let third = table.create() else {
            Issue.record("three creates on an empty table must succeed")
            return
        }
        table.destroy(handle: first)
        table.compact()
        _ = second
        #expect(throws: HandleTableError.corruption) {
            try table.write(handle: third, value: 5)
        }
    }

    @Test("Fault E does not fire when the compact relocated only one entry (strict prefix)")
    func faultESingleRelocationSafe() throws {
        var table = HandleTable()
        guard let first = table.create(), let second = table.create() else {
            Issue.record("two creates on an empty table must succeed")
            return
        }
        table.destroy(handle: first)
        table.compact()
        // Only `second` relocated (slot 1 to slot 0): relocation count 1, below the threshold.
        try table.write(handle: second, value: 5)
    }

    @Test("Fault E does not fire on destroy-then-recreate staleness")
    func faultEDestroyRecreateSafe() throws {
        var table = HandleTable()
        guard let first = table.create() else {
            Issue.record("create on an empty table must succeed")
            return
        }
        table.destroy(handle: first)
        guard let replacement = table.create() else {
            Issue.record("create after destroy must succeed")
            return
        }
        // `first` is stale (generation bumped by destroy), but the bump carried no relocation count.
        try table.write(handle: first, value: 5)
        try table.write(handle: replacement, value: 6)
    }

    @Test("A fresh write after compaction through a new handle succeeds")
    func freshWriteAfterCompactSucceeds() throws {
        var table = HandleTable()
        guard let first = table.create(), table.create() != nil, table.create() != nil else {
            Issue.record("three creates on an empty table must succeed")
            return
        }
        table.destroy(handle: first)
        table.compact()
        guard let fresh = table.create() else {
            Issue.record("create after compact must succeed")
            return
        }
        try table.write(handle: fresh, value: 9)
    }

    @Test("Stale destroy is a silent no-op")
    func staleDestroyIsNoOp() {
        var table = HandleTable()
        guard let first = table.create(), let second = table.create(), let third = table.create() else {
            Issue.record("three creates on an empty table must succeed")
            return
        }
        table.destroy(handle: first)
        table.compact()
        _ = third
        table.destroy(handle: second)
        #expect(table.occupiedCount == 2, "the stale destroy must not free the entry that now occupies the slot")
    }

    @Test("Create returns nil when the table is full")
    func createNilWhenFull() {
        var table = HandleTable()
        for _ in 0 ..< HandleTable.capacity {
            #expect(table.create() != nil)
        }
        #expect(table.create() == nil)
        #expect(table.isFull)
    }
}
