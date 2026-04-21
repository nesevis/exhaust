// A container for referencing entities produced by prior commands in contract tests.
import ExhaustCore

/// Holds values produced by earlier commands so that later commands can reference them.
///
/// Use `Bundle` when a command needs to operate on an entity created by a prior command (for example, deleting a user that was previously created). The drawing mechanism records a `chooseBits` effect in the Freer Monad, making bundle indices reducable by the Reducer.
///
/// ## Example
///
/// ```swift
/// @Contract
/// struct DatabaseSpec {
///     let userIDs = Bundle<UserID>()
///
///     @Command(weight: 3, #gen(.string(), .int(in: 18...65)))
///     mutating func createUser(name: String, age: Int) {
///         let id = db.createUser(name: name, age: age)
///         userIDs.add(id)
///     }
///
///     @Command(weight: 2)
///     mutating func deleteUser() {
///         guard let id = userIDs.draw() else { skip() }
///         db.deleteUser(id: id)
///     }
/// }
/// ```
public final class Bundle<Element>: @unchecked Sendable {
    // @unchecked Sendable: Bundle is only accessed sequentially within a single contract execution. Concurrent access across threads is not supported and would require external synchronization.

    private var elements: [Element] = []

    /// Creates an empty bundle.
    public init() {}

    /// The number of elements currently in the bundle.
    public var count: Int {
        elements.count
    }

    /// Whether the bundle contains any elements.
    public var isEmpty: Bool {
        elements.isEmpty
    }

    /// Stores a value in the bundle for later retrieval by `draw()` or `consume()`.
    ///
    /// - Parameter element: The value to store.
    public func add(_ element: Element) {
        elements.append(element)
    }

    /// Selects a value from the bundle without removing it, or returns `nil` if the bundle is empty.
    ///
    /// The caller should call `skip()` when this returns `nil` to indicate that the command's precondition is not met.
    ///
    /// - Parameter index: The index to draw from, typically provided by a `chooseBits` effect in the generated command runner.
    /// - Returns: The element at the given index (wrapped around), or `nil` if the bundle is empty.
    public func draw(at index: Int) -> Element? {
        guard !elements.isEmpty else { return nil }
        return elements[index % elements.count]
    }

    /// Selects and removes a value from the bundle, or returns `nil` if the bundle is empty.
    ///
    /// Use this for exclusive ownership patterns where an entity should only be used once (for example, consuming a one-time token).
    ///
    /// - Parameter index: The index to consume from, typically provided by a `chooseBits` effect in the generated command runner.
    /// - Returns: The removed element, or `nil` if the bundle is empty.
    public func consume(at index: Int) -> Element? {
        guard !elements.isEmpty else { return nil }
        let wrappedIndex = index % elements.count
        return elements.remove(at: wrappedIndex)
    }
    
    /// Removes all values from the bundle where `predicate` returns `true`.
    ///
    /// Use this when bulk removal of specific elements is required.
    public func remove(where predicate: (Element) -> Bool) {
        elements = elements.filter(predicate)
    }

    /// Removes all elements from the bundle.
    public func reset() {
        elements.removeAll()
    }
}
