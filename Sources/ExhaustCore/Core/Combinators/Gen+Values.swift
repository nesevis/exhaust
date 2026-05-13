// Operations for generating specific constant and validated values.
// These combinators handle scenarios where exact values or validation are required.

package extension Gen {
    /// Creates a generator that always produces the same constant value.
    ///
    /// This generator always succeeds during both generation and reflection phases, regardless of what target value is being reflected against. It's the most permissive constant value generator.
    ///
    /// For validation during reflection, see ``Gen/exact(_:)`` instead.
    ///
    /// - Parameter value: The constant value to always generate.
    /// - Returns: A generator that produces the constant value.
    static func just<Output>(_ value: Output) -> Generator<Output> {
        liftF(.just(value))
    }

    /// Creates a generator that produces an exact constant value with validation during reflection.
    ///
    /// **Key difference from ``Gen/just(_:)``:**
    /// - **``Gen/just(_:)``**: Always succeeds during reflection regardless of target value
    /// - **``Gen/exact(_:)``**: Only succeeds during reflection if target value exactly matches the constant
    ///
    /// **Forward pass (generation):** Always produces the constant value **Backward pass (reflection):** Fails if the target value doesn't match exactly
    ///
    /// Without this validation, reflection would silently accept any value, masking structural mismatches between the generator and the target.
    ///
    /// - Parameter value: The constant value to generate and validate against.
    /// - Returns: A generator that produces the constant and validates during reflection.
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
