// A container for referencing entities produced by prior commands in contract tests.
import Foundation

/// Holds values produced by earlier commands so that later commands can reference them.
///
/// Use ``Bundle`` when a command needs to operate on an entity created by a prior command (for example, deleting a user that was previously created). The drawing mechanism records a ``chooseBits`` effect in the Freer Monad, making bundle indices reducible by the reducer.
///
/// ## Example
///
/// ```swift
/// @Contract(.sequential)
/// final class DatabaseSpec {
///     @SystemUnderTest var db = Database()
///     let userIDs = Bundle<UserID>()
///
///     @Command(weight: 3, .string(), .int(in: 18...65))
///     func createUser(name: String, age: Int) {
///         let id = db.createUser(name: name, age: age)
///         userIDs.add(id)
///     }
///
///     @Command(weight: 2, .int(in: 0...99))
///     func deleteUser(index: Int) throws {
///         guard let id = userIDs.draw(at: index) else { throw skip() }
///         db.deleteUser(id: id)
///     }
/// }
/// ```
public final class Bundle<Element>: @unchecked Sendable {
    // @unchecked Sendable: Element is unconstrained to support non-Sendable reference types (for example, class-based SUTs). The NSLock + nonisolated(unsafe) pattern provides mechanical serialization.
    private nonisolated(unsafe) var _storage = [Element]()
    private let lock = NSLock()

    /// Creates an empty bundle.
    public init() {}

    /// The number of elements currently in the bundle.
    public var count: Int {
        lock.withLocking { _storage.count }
    }

    /// Whether the bundle contains any elements.
    public var isEmpty: Bool {
        lock.withLocking { _storage.isEmpty }
    }

    /// Stores a value in the bundle for later retrieval by ``draw(at:)`` or ``consume(at:)``.
    ///
    /// - Parameter element: The value to store.
    public func add(_ element: Element) {
        lock.withLocking { _storage.append(element) }
    }

    /// Selects a value from the bundle without removing it, or returns `nil` if the bundle is empty.
    ///
    /// The caller should call ``skip()`` when this returns `nil` to indicate that the command's precondition is not met.
    ///
    /// - Parameter index: The index to draw from, typically provided by a ``chooseBits`` effect in the generated command runner.
    /// - Returns: The element at the given index (wrapped around), or `nil` if the bundle is empty.
    public func draw(at index: Int) -> Element? {
        lock.withLocking {
            guard _storage.isEmpty == false else { return nil }
            let count = _storage.count
            return _storage[((index % count) + count) % count]
        }
    }

    /// Selects and removes a value from the bundle, or returns `nil` if the bundle is empty.
    ///
    /// Use this for exclusive ownership patterns where an entity should only be used once (for example, consuming a one-time token).
    ///
    /// - Parameter index: The index to consume from, typically provided by a ``chooseBits`` effect in the generated command runner.
    /// - Returns: The removed element, or `nil` if the bundle is empty.
    public func consume(at index: Int) -> Element? {
        lock.withLocking {
            guard _storage.isEmpty == false else { return nil }
            let count = _storage.count
            let wrappedIndex = ((index % count) + count) % count
            return _storage.remove(at: wrappedIndex)
        }
    }

    /// Removes all values from the bundle where `predicate` returns `true`.
    ///
    /// Use this when bulk removal of specific elements is required.
    public func remove(where predicate: (Element) -> Bool) {
        lock.withLocking { _storage.removeAll(where: predicate) }
    }

    /// Removes all elements from the bundle.
    public func reset() {
        lock.withLocking { _storage.removeAll() }
    }
}
