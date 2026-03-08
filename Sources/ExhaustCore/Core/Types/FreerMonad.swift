/// A free monad implementation that separates effect descriptions from their interpretation.
///
/// FreerMonad enables the description of computations with effects without executing them immediately.
/// This separation allows for:
/// - **Composable effects**: Chain operations without coupling to specific interpreters
/// - **Multiple interpretations**: The same computation can be run with different interpreters
/// - **Testability**: Effects can be mocked or traced during testing
/// - **Optimization**: Interpreters can analyze the entire computation tree before execution
///
/// The monad has two states:
/// - `pure`: Contains a final computed value with no remaining effects
/// - `impure`: Contains a suspended operation awaiting interpretation and a continuation
///
/// **Usage in property-based testing:**
/// FreerMonad forms the foundation for generators that can both produce values (forward pass) and validate against target values (backward pass via reflection).
///
/// - Parameters:
///   - Operation: The type of effects this monad can represent
///   - Value: The type of values this computation ultimately produces
public enum FreerMonad<Operation, Value> {
    /// A pure value representing the successful completion of a computation.
    ///
    /// This case indicates that all effects have been resolved and the computation has produced its final result. No further interpretation is needed.
    case pure(Value)

    /// An impure value representing a suspended computation awaiting interpretation.
    ///
    /// This case contains:
    /// - `operation`: The effect to be interpreted
    /// - `continuation`: A function that processes the effect's result and produces the next step
    ///
    /// The continuation receives `Any` to maintain type erasure across the interpretation boundary, allowing interpreters to work with heterogeneous effect types.
    indirect case impure(operation: Operation, continuation: (Any) throws -> FreerMonad<Operation, Value>)
}

// MARK: - Functor and Monad

public extension FreerMonad {
    /// Monadic bind operation that sequences computations with effects.
    ///
    /// This is the fundamental operation for chaining effectful computations. It allows you to use the result of one computation to determine the next computation, properly handling both pure values and suspended operations.
    ///
    /// **For pure values:** Immediately applies the transform to get the next computation
    /// **For impure values:** Extends the continuation chain to apply the transform later
    ///
    /// This operation is associative and follows the monad laws, enabling safe composition of complex effectful programs from simpler building blocks.
    ///
    /// - Parameter transform: A function that takes the current value and produces a new computation
    /// - Returns: A new computation representing the sequenced effects
    /// - Throws: Rethrows any errors from the transform function
    @inlinable
    func _bind<NewValue>(_ transform: @escaping (Value) throws -> FreerMonad<Operation, NewValue>) rethrows -> FreerMonad<Operation, NewValue> {
        switch self {
        case let .pure(value):
            try transform(value)
        case let .impure(operation, continuation):
            .impure(operation: operation) { try continuation($0)._bind(transform) }
        }
    }

    /// Functor map operation that transforms the final value of a computation.
    ///
    /// This operation applies a pure function to transform the eventual result of the computation without changing the effect structure. It's implemented in terms of `bind` for consistency and simplicity.
    ///
    /// **Key difference from bind:**
    /// - `map` transforms values with pure functions (Value -> NewValue)
    /// - `bind` sequences computations with effects (Value -> FreerMonad<Operation, NewValue>)
    ///
    /// Use `map` when you want to transform the result but don't need to introduce additional effects or change the computational structure.
    ///
    /// - Parameter transform: A pure function to apply to the final value
    /// - Returns: A computation that produces the transformed value
    /// - Throws: Rethrows any errors from the transform function
    @inlinable
    func _map<NewValue>(_ transform: @escaping (Value) throws -> NewValue) rethrows -> FreerMonad<Operation, NewValue> {
        switch self {
        case let .pure(value): try .pure(transform(value))
        case let .impure(operation, continuation):
            .impure(operation: operation) { try continuation($0)._map(transform) }
        }
    }

    /// Erases the specific value type to `Any`, enabling type-heterogeneous operations.
    ///
    /// This operation is essential for implementing interpreters that need to work with computations producing different value types. By erasing to `Any`, we can:
    /// - Store computations with different value types in the same collection
    /// - Pass computations through interpreter boundaries that don't know specific types
    /// - Enable reflection-based operations that work with runtime type information
    ///
    /// **Type safety note:** While this operation sacrifices compile-time type safety, it's typically used in controlled contexts where the interpreter can safely cast values back to their expected types.
    ///
    /// **Performance:** The erasure is structural - it traverses and rebuilds the entire computation tree to change the type parameter. This is necessary because Swift's type system requires the full generic signature to match.
    ///
    /// - Returns: An equivalent computation with value type erased to `Any`
    @inlinable
    func erase() -> FreerMonad<Operation, Any> {
        switch self {
        case let .pure(value):
            .pure(value as Any)
        case let .impure(operation, continuation):
            .impure(operation: operation) { try continuation($0).erase() }
        }
    }
}

// MARK: - Sendable

// FreerMonad is `@unchecked Sendable` because, while it stores closures in its
// `impure` case (which the compiler cannot verify as Sendable), the framework
// guarantees thread safety through two complementary mechanisms:
//
// 1. **Internal closures are framework-controlled and pure by construction.**
//    Every closure inside the generator chain — continuations in `impure`, transforms
//    in `contramap`, predicates in `filter`/`classify`/`unique` — is created by `Gen`
//    combinators or interpreter infrastructure. These closures perform deterministic
//    value transformations (type casts, array indexing, bit pattern conversion) and
//    never capture shared mutable state. The framework is the sole producer of these
//    closures; users cannot inject arbitrary closures into the monad's continuation chain.
//
// 2. **User-injected closures are `@Sendable` at the API boundary.**
//    Every public API that accepts a user-provided closure — `property` in `#exhaust`,
//    `scorer` in `#explore`, `predicate` in `.filter()`, `forward`/`backward` in
//    `.mapped()`, etc. — marks that parameter as `@Sendable`. This means the Swift
//    compiler verifies at each call site that the user's closure captures only `Sendable`
//    values, preventing shared mutable state from entering the system.
//
// Together, these guarantees mean that a `FreerMonad<ReflectiveOperation, Value>` (i.e.
// `ReflectiveGenerator<Value>`) can be safely shared across concurrency domains — for
// example, reusing the same generator across parallel test methods in Swift Testing.
extension FreerMonad: @unchecked Sendable {}

public extension FreerMonad where Value == Any {
    /// Optimized erasure for computations that are already type-erased.
    ///
    /// This specialization provides a no-op implementation of `erase()` for computations where the value type is already `Any`. This avoids unnecessary traversal and reconstruction of the computation tree.
    ///
    /// This optimization handles cases where `erase()` might be called multiple times on the same computation, ensuring idempotency and better performance.
    ///
    /// - Returns: The same computation unchanged (since it's already erased)
    @inlinable
    func erase() -> FreerMonad<Operation, Any> {
        self
    }
}
