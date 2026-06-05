import Exhaust
import ExhaustTestSupport
import Testing

@Suite("Multiple properties", .serialized, .tags(.contract))
struct MultiModelTests {
    @Test("Spec with three properties detects divergence")
    func specWithThreeModelPropertiesDetectsDivergence() {
        let result = #execute(
            MultiModelSpec.self,
            .commandLimit(8),
            .suppress(.issueReporting)
        )
        #expect(result != nil, "Buggy insert should cause model/SUT divergence")
        if let result {
            let hasFailure = result.trace.contains { step in
                if case .invariantFailed = step.outcome { return true }
                return false
            }
            #expect(hasFailure)
        }
    }
}

// MARK: - Spec

@Contract(.sequential)
final class MultiModelSpec {
    var expectedKeys: [String] = []
    var expectedValues: [Int] = []
    var expectedCount: Int = 0
    @SystemUnderTest
    var store: BuggyKeyValueStore = .init()

    @Invariant
    func countMatches() -> Bool {
        store.count == expectedCount
    }

    @Invariant
    func keysMatch() -> Bool {
        store.keys.sorted() == expectedKeys.sorted()
    }

    @Command(weight: 3, .element(from: ["a", "b", "c"]), .int(in: 0 ... 9))
    func insert(key: String, value: Int) throws {
        if expectedKeys.contains(key) == false {
            expectedKeys.append(key)
            expectedCount += 1
        }
        expectedValues.append(value)
        store.insert(key: key, value: value)
    }

    @Command(weight: 2, .element(from: ["a", "b", "c"]))
    func remove(key: String) throws {
        guard expectedKeys.contains(key) else { throw skip() }
        expectedKeys.removeAll { $0 == key }
        expectedCount -= 1
        store.remove(key: key)
    }
}

// MARK: - SUT

/// Key-value store with a bug: insert doesn't update the count when overwriting an existing key.
struct BuggyKeyValueStore {
    private var storage: [String: Int] = [:]
    private var _count: Int = 0

    var count: Int {
        _count
    }

    var keys: [String] {
        Array(storage.keys)
    }

    mutating func insert(key: String, value: Int) {
        storage[key] = value
        _count += 1
    }

    mutating func remove(key: String) {
        if storage.removeValue(forKey: key) != nil {
            _count -= 1
        }
    }
}
