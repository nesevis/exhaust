import ExecuteFixture
import Exhaust
import Foundation

/// Process-wide skip accounting for ``HandleTableSpec`` — the starvation-shape observable (design doc, MX1b).
///
/// Counts every command entry and every precondition skip across all spec instances in the process, including replay, reduction, and skip-pruning re-executions; the intended use is arm-level aggregate comparison, where that inflation applies to every arm equally. The benchmark driver resets before a run and snapshots after.
public enum HandleTableSkipCounters {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var enteredCount = 0
    private nonisolated(unsafe) static var skippedCount = 0

    /// Records one command entry. Entries that go on to precondition-skip are counted here too — the skip fraction's denominator is entries, not completed executions.
    public static func recordEntered() {
        lock.lock()
        enteredCount += 1
        lock.unlock()
    }

    /// Records one precondition skip.
    public static func recordSkipped() {
        lock.lock()
        skippedCount += 1
        lock.unlock()
    }

    /// Returns the counts accumulated since the last reset, then zeroes them.
    public static func snapshotAndReset() -> (entered: Int, skipped: Int) {
        lock.lock()
        defer {
            enteredCount = 0
            skippedCount = 0
            lock.unlock()
        }
        return (entered: enteredCount, skipped: skippedCount)
    }
}

/// The shared spec for the `HandleTable` fixture (fault E — registry in `HandleTable.swift`).
///
/// Skip-heavy by construction: `create` skips when the table is full, `write` and `destroy` skip while the client holds no handles. The spec's handle list models what a client believes is live; compaction silently invalidates it, which is the fault vector.
@StateMachine(.sequential)
public final class HandleTableSpec {
    var handles: [HandleTable.Handle] = []
    @SystemUnderTest var table: HandleTable = .init()

    @Command(weight: 1)
    func create() throws {
        HandleTableSkipCounters.recordEntered()
        guard table.isFull == false else {
            HandleTableSkipCounters.recordSkipped()
            throw skip()
        }
        // Unreachable with the current SUT (create returns nil only when full, checked above); kept as defense so a capacity change in the fixture cannot crash the spec.
        guard let handle = table.create() else {
            HandleTableSkipCounters.recordSkipped()
            throw skip()
        }
        handles.append(handle)
    }

    @Command(weight: 1, .int(in: 0 ... 7), .int(in: 0 ... 9))
    func write(slot: Int, value: Int) throws {
        HandleTableSkipCounters.recordEntered()
        guard handles.isEmpty == false else {
            HandleTableSkipCounters.recordSkipped()
            throw skip()
        }
        let handle = handles[slot % handles.count]
        try table.write(handle: handle, value: value)
    }

    @Command(weight: 1, .int(in: 0 ... 7))
    func destroy(slot: Int) throws {
        HandleTableSkipCounters.recordEntered()
        guard handles.isEmpty == false else {
            HandleTableSkipCounters.recordSkipped()
            throw skip()
        }
        let handle = handles.remove(at: slot % handles.count)
        table.destroy(handle: handle)
    }

    @Command(weight: 1)
    func compact() throws {
        HandleTableSkipCounters.recordEntered()
        table.compact()
    }

    /// Reports the client handle list and table occupancy at the point of failure.
    public func failureDescription() -> String? {
        "handles: \(handles.map { "(\($0.slot),g\($0.generation))" }.joined(separator: " ")), occupied: \(table.occupiedCount)"
    }
}
