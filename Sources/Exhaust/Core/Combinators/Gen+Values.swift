/// Operations for generating specific constant and validated values.
/// These combinators handle scenarios where exact values or validation are required.
public extension Gen {
    /// Creates a generator that always produces the same constant value.
    ///
    /// This generator always succeeds during both generation and reflection phases,
    /// regardless of what target value is being reflected against. It's the most
    /// permissive constant value generator.
    ///
    /// For validation during reflection, see `Gen.exact` instead.
    ///
    /// - Parameter value: The constant value to always generate
    /// - Returns: A generator that produces the constant value
    @inlinable
    static func just<Output>(_ value: Output) -> ReflectiveGenerator<Output> {
        liftF(.just(value))
    }

    /// Creates a generator that produces an exact constant value with validation during reflection.
    ///
    /// **Key difference from `Gen.just`:**
    /// - **`Gen.just`**: Always succeeds during reflection regardless of target value
    /// - **`Gen.exact`**: Only succeeds during reflection if target value exactly matches the constant
    ///
    /// **Forward pass (generation):** Always produces the constant value
    /// **Backward pass (reflection):** Fails if the target value doesn't match exactly
    ///
    /// This validation behavior makes `Gen.exact` essential for property-based testing
    /// where you need to verify that generated structures contain specific expected values.
    ///
    /// - Parameter value: The constant value to generate and validate against
    /// - Returns: A generator that produces the constant and validates during reflection
    @inlinable
    static func exact<Value: Equatable>(_ value: Value) -> ReflectiveGenerator<Value> {
        // Use lmap with a transform that validates the target value during reflection.
        // The transform returns nil for mismatches, causing reflection to fail.
        let baseGenerator = just(value as Any)
        
        let transform: (Any) -> Any? = { inputValue in
            guard let typedInput = inputValue as? Value, typedInput == value else {
                return nil  // Reflection fails for non-matching values
            }
            return typedInput
        }
        
        return liftF(.lmap(transform: transform, next: baseGenerator))
    }
}