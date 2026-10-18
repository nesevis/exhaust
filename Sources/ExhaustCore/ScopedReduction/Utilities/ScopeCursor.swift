/// Delivers complete scopes without exposing whether they were buffered or generated on demand.
///
/// A scope may contain an entire node group; streaming governs enumeration of scopes, not membership within a scope. Cursors are tied to the graph state from which they were prepared and must be discarded when their scope data becomes invalid.
protocol ScopeCursor<Scope> {
    associatedtype Scope

    /// Returns the next complete scope, or nil when enumeration is exhausted.
    mutating func next() -> Scope?
}

/// Preserves a prepared scope order while allowing the same consumer to use generated cursors.
///
/// The caller owns grouping and ordering decisions. Advancing only increments an index, avoiding array shifts and retaining complete group scopes for batch operations.
struct BufferedScopeCursor<Scope> {
    private let scopes: [Scope]
    private var index = 0

    init(_ scopes: [Scope]) {
        self.scopes = scopes
    }

    /// Allows priority adapters to inspect the next scope without consuming it.
    var peekScope: Scope? {
        guard index < scopes.count else {
            return nil
        }
        return scopes[index]
    }
}

extension BufferedScopeCursor: ScopeCursor {
    mutating func next() -> Scope? {
        guard index < scopes.count else {
            return nil
        }
        let scope = scopes[index]
        index += 1
        return scope
    }
}

extension BufferedScopeCursor: Sendable where Scope: Sendable {}
