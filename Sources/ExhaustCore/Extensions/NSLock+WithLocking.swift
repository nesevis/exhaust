import Foundation

package extension NSLock {
    /// Runs `body` while holding the lock. Use for closure-shaped critical sections; brackets that span statements (early unlocks, code between lock and unlock) keep explicit `lock()`/`unlock()` calls.
    func withLocking<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock()
        defer { unlock() }
        return try body()
    }
}
