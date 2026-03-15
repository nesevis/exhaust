// MARK: - Key-Value Store Lifecycle Contract Test
//
// Inspired by ScalaCheck's `CommandsLevelDB.scala` (Rickard Nilsson, ScalaCheck project).
//
// The original tests a LevelDB wrapper where `open`, `close`, `put`, and
// `get` must respect a lifecycle protocol — puts and gets are only valid
// when the store is open, and opening an already-open store is invalid.
// This port replaces the external database with an in-memory key-value store
// and embeds a lifecycle bug: `close` does not clear storage, so data from
// a previous session persists after a close/reopen cycle.
//
// This is the first Contract integration test to exercise lifecycle-gated
// commands, where an entire group of operations becomes invalid based on a
// boolean flag. The `skip()` calls on `put`, `get`, and `close` when the
// store is closed (and on `open` when already open) test that the contract
// runner correctly handles high skip rates without false positives.

import Testing
import Exhaust
import ExhaustCore

// MARK: - Tests

@Suite("Key-value store lifecycle contract tests")
struct KVStoreLifecycleTests {
    @Test("Stale data after close/reopen detected via invariant or postcondition")
    func staleDataAfterReopen() throws {
        // Bonsai is more or less equivalent here
        let result = try #require(
            #exhaust(
                KVStoreLifecycleContract.self,
                commandLimit: 10,
                .suppressIssueReporting,
                .useBonsaiReducer
            )
        )

        #expect(result.trace.contains { step in
            switch step.outcome {
            case .invariantFailed, .checkFailed: return true
            default: return false
            }
        })
    }
}

// MARK: - Contract

// The model tracks `isOpen` and a `contents` dictionary. On `close`, the
// model clears its contents (the correct behavior). After a close/reopen
// cycle, the model expects an empty store, but the buggy SUT retains its
// previous data — the invariant catches this divergence.
//
// The small key domain (0...3) ensures key collisions across sessions,
// making it likely that a `get` after reopen returns a stale value that
// the model does not expect.

@Contract
struct KVStoreLifecycleContract {
    @Model var isOpen = false
    @Model var contents: [Int: Int] = [:]
    @SUT var store = BuggyKVStore()

    @Invariant
    func countMatchesWhenOpen() -> Bool {
        guard isOpen else { return true }
        return store.count == contents.count
    }

    @Command(weight: 2)
    mutating func open() throws {
        guard !isOpen else { throw skip() }
        isOpen = true
        store.open()
    }

    @Command(weight: 2)
    mutating func close() throws {
        guard isOpen else { throw skip() }
        isOpen = false
        contents = [:]
        store.close()
    }

    @Command(weight: 4, Gen.int(in: 0...3), Gen.int(in: 0...99))
    mutating func put(key: Int, value: Int) throws {
        guard isOpen else { throw skip() }
        contents[key] = value
        store.put(key, value)
    }

    @Command(weight: 3, Gen.int(in: 0...3))
    mutating func get(key: Int) throws {
        guard isOpen else { throw skip() }
        let actual = store.get(key)
        let expected = contents[key]
        try check(actual == expected, "get must return value matching model")
    }
}

// MARK: - Types

// An in-memory key-value store with explicit open/close lifecycle. The bug:
// `close` sets the open flag to false but does not clear the underlying
// storage. A correct implementation would wipe storage on close so that a
// fresh `open` starts with an empty store.

struct BuggyKVStore {
    private var storage: [Int: Int] = [:]
    private(set) var isOpen = false

    mutating func open() {
        isOpen = true
    }

    mutating func close() {
        isOpen = false
        // Bug: does not clear storage — stale data survives close/reopen cycles
    }

    mutating func put(_ key: Int, _ value: Int) {
        storage[key] = value
    }

    func get(_ key: Int) -> Int? {
        storage[key]
    }

    var count: Int { storage.count }
}
