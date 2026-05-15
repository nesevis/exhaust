// MARK: - Academic Provenance

//
// Freer Monad from Kiselyov and Ishii, "Freer Monads, More Extensible Effects" (Haskell Symposium 2015). Goldstein et al., "Reflecting on Random Generation" (ICFP 2023), §3.2 chose it as the encoding for reflective generators.
//
// A closure-based generator (QuickCheck's `Gen a = Int -> a`) is a black box: it can only be run forward. The Freer Monad lifts each generator decision out of closures and into an inspectable data structure — a chain of `ReflectiveOperation` nodes connected by continuations. Because the decisions are data, not control flow, the same generator can be interpreted in multiple ways: forward (generation), backward (reflection), deterministic replay, adaptation (CGS tuning), coverage analysis, and graph-based reduction all operate on the same `FreerMonad` value without the generator author writing mode-specific code.
//
// Goldstein et al. considered a tagless-final encoding but found it more tedious to program with and no more expressive. The Freer Monad's concrete data representation is what makes the multi-interpretation architecture practical: interpreters pattern-match on operations rather than threading effect handlers through type class dictionaries.

/// Reifies generator decisions as inspectable data rather than opaque closures.
///
/// A closure-based generator can only be run forward. Each closure boundary is opaque: reflection, replay, coverage analysis, and graph-based reduction cannot see through it. The Freer Monad encoding eliminates this limitation by suspending each decision as a ``ReflectiveOperation`` node with an explicit continuation. The same generator structure can then be interpreted in any direction by any interpreter.
///
/// `.pure` carries a final value with no remaining decisions. `.impure` carries the next decision and a continuation that consumes the interpreter's answer.
///   - Operation: The type of effects this monad can represent.
///   - Value: The type of values this computation ultimately produces.
public indirect enum FreerMonad<Operation, Value> { // NOTE: The entire enum is marked as `indirect` for performance reasons
    /// The terminal state. Interpreters return the contained value directly without further traversal. Pure nodes produce no entries in the ``ChoiceSequence``: they carry the result but no randomness.
    case pure(Value)

    /// A suspended effect awaiting interpretation. The `operation` describes what randomness to consume or what structural choice to make; the `continuation` transforms the interpreter's result into the next step. The continuation takes `Any` because operations are type-erased: each case carries heterogeneous associated values that the continuation casts back to the expected type.
    case impure(
        operation: Operation,
        continuation: (Any) throws -> FreerMonad<Operation, Value>
    )
}

// MARK: - Functor and Monad

package extension FreerMonad {
    /// Sequences two computations; uses the result of this one to determine the next.
    ///
    /// For `.pure`, applies the transform immediately. For `.impure`, extends the continuation chain so the transform runs after the operation is interpreted. This is the invisible plumbing behind every generator combinator: `Gen.arrayOf`, `Gen.pick`, and `Gen.zip` all compose via `bind`.
    ///
    /// - Parameter transform: A function that takes the current value and produces a new computation.
    /// - Returns: A new computation representing the sequenced effects.
    /// - Throws: Rethrows any errors from the transform function.
    func bind<NewValue>(
        _ transform: @escaping (Value) throws -> FreerMonad<Operation, NewValue>
    ) rethrows -> FreerMonad<Operation, NewValue> {
        switch self {
        case let .pure(value):
            try transform(value)
        case let .impure(operation, continuation):
            .impure(operation: operation) { try continuation($0).bind(transform) }
        }
    }

    /// Transforms the eventual result without introducing new effects.
    ///
    /// Unlike ``bind(_:)``, which can introduce additional operations, `map` only changes the value at the end of the chain. The effect structure (which operations run, in what order) remains unchanged. This is the invisible `map` that powers `Gen.contramap` and the macro's backward-mapping infrastructure.
    ///
    /// - Parameter transform: A pure function to apply to the final value.
    /// - Returns: A computation that produces the transformed value.
    /// - Throws: Rethrows any errors from the transform function.
    func map<NewValue>(
        _ transform: @escaping (Value) throws -> NewValue
    ) rethrows -> FreerMonad<Operation, NewValue> {
        switch self {
        case let .pure(value): try .pure(transform(value))
        case let .impure(operation, continuation):
            .impure(operation: operation) { try continuation($0).map(transform) }
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
    /// - Returns: An equivalent computation with value type erased to `Any`.
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

/// FreerMonad is `@unchecked Sendable` because, while it stores closures in its `impure` case (which the compiler cannot verify as Sendable), the framework guarantees thread safety through two complementary mechanisms:
///
/// 1. **Internal closures are framework-controlled and pure by construction.**
///    Every closure inside the generator chain — continuations in `impure`, transforms in `contramap`, predicates in `filter`/`classify`/`unique` — is created by ``Gen`` combinators or interpreter infrastructure. These closures perform deterministic value transformations (type casts, array indexing, bit pattern conversion) and never capture shared mutable state. The framework is the sole producer of these closures; users cannot inject arbitrary closures into the monad's continuation chain.
///
/// 2. **User-injected closures are `@Sendable` at the API boundary.**
///    Every public API that accepts a user-provided closure — `property` in `#exhaust` and `#explore`, direction predicates in `#explore`, `predicate` in `.filter()`, `forward`/`backward` in `.mapped()`, and so on — marks that parameter as `@Sendable`. This means the Swift compiler verifies at each call site that the user's closure captures only `Sendable` values, preventing shared mutable state from entering the system.
///
/// Together, these guarantees mean that a `FreerMonad<ReflectiveOperation, Value>` (that is, `Generator<Value>`) can be safely shared across concurrency domains — for example, reusing the same generator across parallel test methods in Swift Testing.
extension FreerMonad: @unchecked Sendable {}

package extension FreerMonad where Value == Any {
    /// Optimized erasure for computations that are already type-erased.
    ///
    /// This specialization provides a no-op implementation of `erase()` for computations where the value type is already `Any`. This avoids unnecessary traversal and reconstruction of the computation tree.
    ///
    /// This optimization handles cases where `erase()` might be called multiple times on the same computation, ensuring idempotency and better performance.
    ///
    /// - Returns: The same computation unchanged (since it's already erased).
    func erase() -> FreerMonad<Operation, Any> {
        self
    }
}
