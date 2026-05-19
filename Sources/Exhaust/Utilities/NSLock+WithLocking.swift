import Foundation

extension NSLock {
    @inlinable
    func withLocking<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock()
        defer { unlock() }
        return try body()
    }
}
