import Foundation

// MARK: - Built-generator caches

/// Holds the generator a `.lazy` node built on first use so later passes reuse it instead of rebuilding.
///
/// Stores the erased form because that is what the bind continuation hands to the interpreter; holding the typed generator would cost an `erase()` copy per draw. The lock is held across the miss, the build, and the publish, so when several lanes reach an empty slot at once exactly one of them builds and the rest wait for its result: construction never calls back into interpretation, so nothing inside `build` can reach this lock again. The method takes a non-escaping closure, so callers never capture a non-`Sendable` value in a `@Sendable` context.
package final class BuiltGeneratorSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var built: AnyGenerator?

    package init() {}

    /// Returns the built generator, running `build` under the lock on the first call only.
    package func generator(orBuild build: () throws -> AnyGenerator) rethrows -> AnyGenerator {
        lock.lock()
        defer { lock.unlock() }
        if let existing = built {
            return existing
        }
        let generator = try build()
        built = generator
        return generator
    }
}

/// Holds the generators a caching bind built, one per distinct bound value, in erased form and under the same single-flight locking as ``BuiltGeneratorSlot``.
///
/// Unbounded, since the API contract restricts it to small value sets. One lock covers the whole table, so lanes building generators for different keys serialise; construction is a one-off per key, so that costs nothing once the table is warm.
package final class BuiltGeneratorTable<Key: Hashable>: @unchecked Sendable {
    private let lock = NSLock()
    private var built: [Key: AnyGenerator] = [:]

    package init() {}

    /// Returns the generator for `key`, running `build` under the lock on the first call for that key only.
    package func generator(for key: Key, orBuild build: () throws -> AnyGenerator) rethrows -> AnyGenerator {
        lock.lock()
        defer { lock.unlock() }
        if let existing = built[key] {
            return existing
        }
        let generator = try build()
        built[key] = generator
        return generator
    }
}
