// Operations for generating specific constant and validated values.
// These combinators handle scenarios where exact values or validation are required.

package extension Gen {
    /// Produces a constant value, accepting any target during reflection.
    ///
    /// Use `just` for base cases and placeholders where the constant's identity does not matter to the property — for example, default branches in a ``pick`` or leaf values in ``recursive(base:depthRange:extend:)``. Because reflection always succeeds regardless of the target value, `just` cannot detect structural mismatches. When the constant must match exactly during reflection, use ``exact(_:)`` instead.
    ///
    /// - Parameter value: The constant value to always generate.
    /// - Returns: A generator that produces `value` on every invocation.
    static func just<Output>(_ value: Output) -> Generator<Output> {
        liftF(.just(value))
    }

    /// Produces a constant value, rejecting mismatches during reflection.
    ///
    /// Use `exact` when the constant carries structural meaning and a wrong value should cause the reflection branch to fail — for example, a fixed delimiter in a parsed format, or a sentinel in an enum payload. Generation always produces `value`. Reflection succeeds only when the target equals `value`; otherwise it returns nil and the enclosing ``prune`` eliminates the branch. When match validation is not needed, use ``just(_:)`` instead.
    ///
    /// - Parameter value: The constant value to generate and validate against.
    /// - Returns: A generator that produces `value` and rejects non-matching targets during reflection.
    static func exact<Value: Equatable>(_ value: Value) -> Generator<Value> {
        // Use contramap with a transform that validates the target value during reflection.
        // The transform returns nil for mismatches, causing reflection to fail.
        let baseGenerator = just(value as Any)

        let transform: (Any) -> Any? = { inputValue in
            guard let typedInput = inputValue as? Value, typedInput == value else {
                return nil // Reflection fails for non-matching values
            }
            return typedInput
        }

        return liftF(.contramap(transform: transform, next: baseGenerator))
    }
}
