import Foundation

/// Records the values a generator produced, in order, so a test can compare what a cached and an uncached build drew.
///
/// The name distinguishes it from the string-rendering recorder the replay corpus keeps for its own suite.
final class DrawnValueRecorder: @unchecked Sendable {
    private(set) var values: [Int] = []

    func append(_ value: Int) {
        values.append(value)
    }
}

/// Counts how many times a generator was built, and under which keys.
///
/// Both questions share one counter because the key-taking `increment(_:)` is the plain `increment()` plus a key insert. A deferral test asks only whether a build happened, so it calls the bare form and reads ``isEmpty``; a caching test asks which distinct keys caused a build, so it passes the key and reads ``distinctValues``.
final class ConstructionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    private var seen: Set<Int> = []

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var isEmpty: Bool {
        count < 1
    }

    var distinctValues: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return seen.sorted()
    }

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        storage += 1
    }

    func increment(_ value: Int) {
        lock.lock()
        defer { lock.unlock() }
        storage += 1
        seen.insert(value)
    }
}
