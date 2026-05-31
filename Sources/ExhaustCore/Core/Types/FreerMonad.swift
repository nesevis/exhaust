// MARK: - Academic Background

//
// Freer Monad from Kiselyov and Ishii, "Freer Monads, More Extensible Effects" (Haskell Symposium 2015). Goldstein et al., "Reflecting on Random Generation" (ICFP 2023), section 3.2 chose it as the encoding for reflective generators.
//
// A closure-based generator (QuickCheck's `Gen a = Int -> a`) is a black box: it can only be run forward. The Freer Monad lifts each generator decision out of closures and into an inspectable data structure — a chain of `ReflectiveOperation` nodes connected by continuations. Because the decisions are data, not control flow, the same generator can be interpreted in multiple ways: forward (generation), backward (reflection), deterministic replay, adaptation (CGS tuning), coverage analysis, and graph-based reduction all operate on the same `FreerMonad` value without the generator author writing mode-specific code.
//
// The Freer Monad's concrete data representation is what makes the multi-interpretation architecture practical: interpreters pattern-match on operations rather than threading effect handlers through type class dictionaries.

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

    /// A suspended effect awaiting interpretation. The `operation` describes what randomness to consume or what structural choice to make; the `continuation` transforms the interpreter's result into the next step. The continuation takes `Any` because operations are type-erased, and it *returns* `Any` so the continuation chain never needs re-erasing as it is walked: `Value` is a static claim recovered by a cast at the interpreter boundary, concrete only at `.pure` leaves.
    case impure(
        operation: Operation,
        continuation: (Any) throws -> FreerMonad<Operation, Any>
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
                // swiftlint:disable:next force_cast
                .impure(operation: operation) { input in try continuation(input).bind { try transform($0 as! Value).erase() } }
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
                // swiftlint:disable:next force_cast
                .impure(operation: operation) { input in try continuation(input).map { try transform($0 as! Value) as Any } }
        }
    }

    /// Erases the value type to `Any` so computations with different output types can be stored together and passed through interpreter boundaries.
    ///
    /// Because continuations already produce `Any`, erasure is O(1) per node and does not rebuild the chain: `.pure` reboxes its value and `.impure` reuses its operation and continuation unchanged. The ``FreerMonad/erase()-1loq6`` specialization for `Value == Any` short-circuits even the `.pure` reboxing.
    ///
    /// - Returns: An equivalent computation with value type erased to `Any`.
    func erase() -> FreerMonad<Operation, Any> {
        switch self {
            case let .pure(value):
                .pure(value as Any)
            case let .impure(operation, continuation):
                .impure(operation: operation, continuation: continuation)
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
    /// Short-circuits erasure when the value type is already `Any`, avoiding the chain traversal that the generic ``erase()`` would otherwise perform.
    ///
    /// - Returns: `self`, unchanged.
    func erase() -> FreerMonad<Operation, Any> {
        self
    }
}
