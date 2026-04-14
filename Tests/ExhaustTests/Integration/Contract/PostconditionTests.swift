import Exhaust
import Testing

// MARK: - Tests

@Suite("Postcondition-only contract tests")
struct PostconditionTests {
    @Test("Set uniqueness postcondition detects duplicate add")
    func setDuplicateDetection() throws {
        let result = try #require(
            #exhaust(
                SetUniquenessContract.self,
                commandLimit: 5,
                .suppress(.issueReporting)
            )
        )

        #expect(result.trace.contains { step in
            if case .checkFailed = step.outcome { return true }
            return false
        })
    }

    @Test("Stack LIFO postcondition detects wrong peek")
    func stackLIFOViolation() throws {
        let result = try #require(
            #exhaust(
                StackLIFOContract.self,
                commandLimit: 4,
                .suppress(.issueReporting)
            )
        )

        #expect(result.trace.contains { step in
            if case .checkFailed = step.outcome { return true }
            return false
        })
    }

    @Test("Dictionary consistency detects count drift")
    func dictionaryCountDrift() throws {
        let result = try #require(
            #exhaust(
                DictionaryConsistencyContract.self,
                commandLimit: 6,
                .suppress(.issueReporting)
            )
        )

        // Could be either invariant failure (count mismatch) or check failure
        #expect(result.trace.contains { step in
            switch step.outcome {
            case .invariantFailed, .checkFailed: true
            default: false
            }
        })
    }
}

// MARK: - Contract: Set uniqueness

@Contract
struct SetUniquenessContract {
    @SUT var uniqueSet = BuggySet<Int>()

    @Command(weight: 3, .int(in: 0 ... 3))
    mutating func add(element: Int) throws {
        uniqueSet.add(element)
        // Postcondition: after add, the element is present
        try check(uniqueSet.contains(element), "added element must be contained")
        // Postcondition: no duplicates — count of this element should be 1
        let occurrences = uniqueSet.elements.count(where: { $0 == element })
        try check(occurrences == 1, "set must not contain duplicates")
    }

    @Command(weight: 2, .int(in: 0 ... 3))
    mutating func remove(element: Int) throws {
        uniqueSet.remove(element)
        // Postcondition: after remove, the element is gone
        try check(!uniqueSet.contains(element), "removed element must not be contained")
    }

    @Command(weight: 1)
    mutating func checkCount() throws {
        // Self-consistency: count equals the number of unique elements
        let unique = Set(uniqueSet.elements).count
        try check(uniqueSet.count == unique, "count must equal unique element count")
    }
}

// MARK: - Contract: Stack LIFO ordering

@Contract
struct StackLIFOContract {
    @SUT var stack = BuggyStack<Int>()

    @Command(weight: 3, .int(in: 0 ... 9))
    mutating func push(value: Int) throws {
        let previousCount = stack.count
        stack.push(value)
        // Postcondition: after push(x), peek returns x
        try check(stack.peek() == value, "peek must return last pushed value")
        // Postcondition: count increased by 1
        try check(stack.count == previousCount + 1, "count must increase by 1")
    }

    @Command(weight: 2)
    mutating func pop() throws {
        guard !stack.isEmpty else { throw skip() }
        let previousCount = stack.count
        _ = stack.pop()
        // Postcondition: count decreased by 1
        try check(stack.count == previousCount - 1, "count must decrease by 1")
    }
}

// MARK: - Contract: Dictionary consistency

@Contract
struct DictionaryConsistencyContract {
    @SUT var dict = TrackedDictionary()

    @Invariant
    func countIsConsistent() -> Bool {
        dict.trackedCount == dict.actualCount
    }

    @Command(weight: 3, .int(in: 0 ... 4), .int(in: 0 ... 99))
    mutating func set(key: Int, value: Int) throws {
        dict.set(key, value)
        // Postcondition: the value is retrievable
        try check(dict.get(key) == value, "get must return set value")
    }

    @Command(weight: 2, .int(in: 0 ... 4))
    mutating func remove(key: Int) throws {
        dict.remove(key)
        // Postcondition: the key is gone
        try check(dict.get(key) == nil, "removed key must return nil")
    }
}

// MARK: - Types

/// A "set" backed by an array. The bug: `add` doesn't check for duplicates,
/// so repeated adds of the same value violate the uniqueness postcondition.
struct BuggySet<Element: Equatable> {
    private(set) var elements: [Element] = []

    mutating func add(_ element: Element) {
        // Bug: doesn't check for duplicates
        elements.append(element)
    }

    mutating func remove(_ element: Element) {
        elements.removeAll { $0 == element }
    }

    func contains(_ element: Element) -> Bool {
        elements.contains(element)
    }

    var count: Int {
        elements.count
    }
}

/// A stack that should obey LIFO ordering. The bug: `push` inserts at the
/// front instead of appending, so `peek` returns the wrong element.
struct BuggyStack<Element: Equatable> {
    private(set) var elements: [Element] = []

    mutating func push(_ element: Element) {
        // Bug: inserts at front instead of end
        elements.insert(element, at: 0)
    }

    mutating func pop() -> Element? {
        guard !elements.isEmpty else { return nil }
        return elements.removeLast()
    }

    func peek() -> Element? {
        elements.last
    }

    var isEmpty: Bool {
        elements.isEmpty
    }

    var count: Int {
        elements.count
    }
}

/// A dictionary wrapper. The bug: `remove` decrements count even when the
/// key doesn't exist, causing count to drift from the actual element count.
struct TrackedDictionary {
    private var storage: [Int: Int] = [:]
    private(set) var trackedCount = 0

    mutating func set(_ key: Int, _ value: Int) {
        if storage[key] == nil {
            trackedCount += 1
        }
        storage[key] = value
    }

    mutating func remove(_ key: Int) {
        storage.removeValue(forKey: key)
        // Bug: decrements count unconditionally, even if key didn't exist
        trackedCount -= 1
    }

    func get(_ key: Int) -> Int? {
        storage[key]
    }

    var actualCount: Int {
        storage.count
    }
}
