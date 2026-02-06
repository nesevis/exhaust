/// A bidirectional generator that can both produce values and reflect on them.
///
/// ReflectiveGenerator is the foundation of advanced property-based testing, enabling generators
/// that work in **three distinct modes**:
///
/// ## 1. Generation (Forward Pass)
/// Produces random values using entropy, just like traditional generators.
///
/// ## 2. Reflection (Backward Pass)  
/// **Key innovation**: Analyzes any value to discover which random choices could have produced it.
///
/// ## 3. Replay (Deterministic Forward)
/// Recreates exact values from recorded choice paths.
///
/// ## Why This Matters
///
/// Traditional generators lose the connection between values and the randomness that produced them.
/// ReflectiveGenerator **reconstructs that connection**, enabling:
///
/// - **Shrinking without traces**: Shrink any value, even from crash reports or external sources
/// - **Mutation testing**: Modify values while preserving validity constraints  
/// - **Example-based generation**: Generate similar values to provided examples
/// - **Validation**: Check if values could have been produced by a generator
///
/// ## Implementation
///
/// ReflectiveGenerator is a type alias for `FreerMonad<ReflectiveOperation, Output>`, separating
/// the description of generation from its interpretation. This enables the same generator structure
/// to be used for all three modes through different interpreters.
///
/// **Construction**: Use `Gen` combinators, never construct directly.
///
/// - SeeAlso: `Gen` for generator construction, `Interpreters` for execution
public typealias ReflectiveGenerator<Output> = FreerMonad<ReflectiveOperation, Output>

public extension ReflectiveGenerator where Operation == ReflectiveOperation {

    /// The bit pattern range associated with this generator's immediate choice operation.
    ///
    /// For generators wrapping a `chooseBits` operation, returns the min/max range that
    /// constrains the random values. Returns `nil` for pure values or non-choice operations.
    ///
    /// This property is used internally for optimization and analysis of generator constraints.
    ///
    /// - Returns: The UInt64 range for choice operations, or nil if not applicable
    var associatedRange: ClosedRange<UInt64>? {
        switch self {
        case .pure:
            return nil
        case let .impure(op, _):
            guard case .chooseBits(let min, let max, _) = op else {
                return nil
            }
            return min...max
        }
    }

    /// Creates a bidirectional transformation of this generator using forward and backward functions.
    ///
    /// This is the fundamental operation for adapting generators to work with different types
    /// while preserving the bidirectional capability. Both directions must be provided:
    ///
    /// - **Forward**: Transforms generated values to the new output type
    /// - **Backward**: During reflection, transforms target values back to the original type
    ///
    /// - Parameters:
    ///   - forward: Function to transform generated values
    ///   - backward: Function to transform reflection targets back to original type
    /// - Returns: A generator producing values of the new output type
    /// - Throws: Rethrows errors from the transformation functions
    @inlinable
    func mapped<NewOutput>(
        forward: @escaping (Value) throws -> NewOutput,
        backward: @escaping (NewOutput) throws -> Value
    ) rethrows -> ReflectiveGenerator<NewOutput> {
        try Gen.contramap(backward, self.map(forward))
    }
    
    /// Creates a bidirectional transformation using a forward function and a partial path for backward.
    ///
    /// This overload uses a `PartialPath` for the backward transformation, which can fail gracefully
    /// when the reflection target doesn't contain the expected structure. If extraction fails,
    /// that reflection branch is pruned.
    ///
    /// - Parameters:
    ///   - forward: Function to transform generated values
    ///   - backward: Partial path to extract the original value from the new type
    /// - Returns: A generator producing values of the new output type
    /// - Throws: Rethrows errors from the forward transformation
    @inlinable
    func mapped<NewOutput>(
        forward: @escaping (Value) throws -> NewOutput,
        backward: some PartialPath<NewOutput, Value>
    ) rethrows -> ReflectiveGenerator<NewOutput> {
        let erasedBackward: (Any) throws -> Any = { newOutput in
            try backward.extract(from: newOutput)!
        }
        let erasedGen = try self
            .map(forward)

        return Gen.contramap(erasedBackward, erasedGen)
    }
    
    /// Creates a bidirectional transformation using partial paths in both directions.
    ///
    /// This overload uses partial paths for both transformations, making both directions
    /// potentially fallible. When either direction fails, that branch is pruned.
    /// The result type is optional to handle extraction failures.
    ///
    /// - Parameters:
    ///   - forward: Partial path to transform from original to new type
    ///   - backward: Partial path to transform back during reflection
    /// - Returns: A generator producing optional values of the new type
    /// - Throws: Errors from path extraction during setup
    @inlinable
    func mapped<NewOutput>(
        forward: some PartialPath<Value, NewOutput>,
        backward: some PartialPath<NewOutput, Value>
    ) throws -> ReflectiveGenerator<NewOutput?> {
        let erasedBackward: (Any) throws -> Any = { newOutput in
            // FIXME: Should we be force unwrapping here? What if it's optional?
            try backward.extract(from: newOutput)!
        }
        let erasedGen = try self
            .map { try forward.extract(from: $0) }
        
        return Gen.contramap(erasedBackward, erasedGen)
    }
    
    /// Converts this generator to produce optional values, enabling nil/non-nil choice patterns.
    ///
    /// This transformation is essential for generators that need to handle optional types
    /// or work with nullable fields. During reflection, it properly handles the distinction
    /// between `.none` and `.some(value)` cases.
    ///
    /// **Reflection behavior**: When reflecting on `nil`, throws `ReflectionError.reflectedNil`
    /// to signal that the non-optional branch should be pruned. When reflecting on `.some(value)`,
    /// extracts the wrapped value for the underlying generator to reflect on.
    ///
    /// - Returns: A generator that produces optional versions of the original values
    @inlinable
    func asOptional() -> ReflectiveGenerator<Value?> {
        let description = String(describing: Value.self)
        return .impure(operation: .contramap(
            transform: { result in
                // Backward pass. The calling function is expecting a non-optional, so we throw the `reflectedNil` error to indicate to the consumer — which should only be a `pick` exploring the nil and non-nil options — that they are trying to parse the `.some` branch using the `.none` value during reflection
                // TODO: Can we verify that this closure is executed from a `pick`?
                if let optional = result as? Optional<Value>, optional == nil {
                    throw Interpreters.ReflectionError.reflectedNil(type: description)
                }
                return result as! Value
            },
            next: self.erase()
        )) { result in
                .pure(result as? Value)
            }
    }
    
    /// Creates an array generator with length constrained to the specified range.
    ///
    /// This is a convenience method that transforms a single-value generator into an array generator
    /// where the array length is randomly chosen from the given range. It provides a clean interface
    /// for generating collections without manually composing `Gen.arrayOf` calls.
    ///
    /// **Forward pass**: Generates a random length within range, then generates that many elements
    /// **Backward pass**: Decomposes target array and reflects on both length and individual elements  
    /// **Replay pass**: Uses recorded length and element choices to recreate the exact array
    ///
    /// The method name "proliferate" suggests the multiplication of a single generator into many
    /// instances, which is exactly what array generation accomplishes while maintaining the
    /// bidirectional properties essential for reflection and replay.
    ///
    /// - Parameter range: The allowed range for the resulting array length
    /// - Returns: A generator that produces arrays with length in the specified range
    @inlinable
    func proliferate(with range: ClosedRange<UInt64>) -> ReflectiveGenerator<[Value]> {
        Gen.arrayOf(self, Gen.choose(in: range))
    }
    
    /// Creates a filtered generator that only produces values satisfying a validity condition.
    ///
    /// This combinator wraps the current generator with a validity predicate, enabling automatic
    /// optimization through Choice Gradient Sampling (CGS) or fallback to rejection sampling.
    /// The filter operation signals to the framework that this generator has specific validity
    /// requirements that could benefit from intelligent optimization.
    ///
    /// **Optimization Strategy**:
    /// - **CGS-suitable generators**: The system analyzes which random choices lead to predicate
    ///   satisfaction and biases future generation toward valid outputs
    /// - **CGS-unsuitable generators**: Falls back to deterministic rejection sampling using a
    ///   separate PRNG to maintain reproducibility
    ///
    /// **Deterministic Behavior**: Even with rejection sampling, the filtered generator maintains
    /// deterministic behavior. Given the same seed, it will reject the same sequence of invalid
    /// values and accept the same valid value, preserving reproducibility for testing.
    ///
    /// **Performance Considerations**: Filtering can significantly improve test efficiency by
    /// reducing wasted generation attempts, especially when combined with CGS optimization.
    /// However, overly restrictive predicates may still require many rejection attempts.
    ///
    /// ```swift
    /// // Example: Generate only positive integers
    /// let positiveInts = Gen.choose(in: Int.min...Int.max)
    ///     .filter { $0 > 0 }
    ///
    /// // Example: Generate balanced binary search trees
    /// let balancedBST = BinaryTree.arbitrary
    ///     .filter { tree in tree.isBalanced && tree.satisfiesBSTProperty }
    /// ```
    ///
    /// **Fingerprinting**: The implementation automatically generates a unique fingerprint for
    /// each filter operation, enabling the optimization system to cache and reuse learned
    /// gradients across different instances with the same logical constraints.
    ///
    /// - Parameter predicate: Validity condition that generated values must satisfy
    /// - Returns: A filtered generator that only produces valid values
    @inlinable
    func filter(_ predicate: @escaping (Value) -> Bool) -> ReflectiveGenerator<Value> {
        // TODO: This is probably slightly too expensive?
        var prng = Xoshiro256()
        return switch self {
        case .pure:
            // This shouldn't happen? Should it be a no-op, or an error? Should we throw in the continuation?
            .impure(
                operation: .filter(gen: self.erase(), fingerprint: prng.next(), predicate: { value in predicate(value as! Value) }),
                continuation: { .pure($0 as! Value) }
            )
        case .impure:
            // How can we fingerprint the generator here. Generate a random value? UUID?
            .impure(
                operation: .filter(gen: self.erase(), fingerprint: prng.next(), predicate: { value in predicate(value as! Value) }),
                continuation: { .pure($0 as! Value) }
            )
        }
    }
    
    @inlinable
    func compose<OtherValue>(with other: ReflectiveGenerator<OtherValue>) -> ReflectiveGenerator<(Value, OtherValue)> {
        Gen.zip(self, other)
    }
    
    /// Transforms the operation type of this generator while preserving the value type.
    ///
    /// **Warning**: This operation has significant performance overhead as it must traverse
    /// and rebuild the entire generator structure. Use sparingly and prefer type-safe alternatives.
    ///
    /// This is an internal utility for advanced generator transformations that need to change
    /// the underlying operation type (e.g., wrapping `ReflectiveOperation` in a larger operation type).
    ///
    /// The transformation is applied recursively to all operations in the generator tree,
    /// requiring a complete structural traversal.
    ///
    /// - Parameter transform: Function to convert operations to the new operation type
    /// - Returns: An equivalent generator with transformed operation type
    /// - Note: Marked private due to performance concerns and specialized use cases
    #warning("This has performance overhead, use with caution")
    func mapOperation<NewOperation>(_ transform: @escaping (Operation) -> NewOperation) -> FreerMonad<NewOperation, Value> {
        switch self {
        case let .pure(value):
            // If we're at a pure value, there's no operation to transform. Return as is.
            return .pure(value)
            
        case let .impure(operation, continuation):
            // If we have a suspended operation:
            // 1. Transform the current operation.
            let newOperation = transform(operation)
            
            // 2. Create a new continuation. This new continuation must return a monad
            //    with the NewOperation type. We do this by recursively calling
            //    `mapOperation` on the result of the original continuation.
            let newContinuation = { (val: Any) -> FreerMonad<NewOperation, Value> in
                try continuation(val).mapOperation(transform)
            }
            
            // 3. Return a new impure case with the transformed operation and continuation.
            return .impure(operation: newOperation, continuation: newContinuation)
        }
    }
}
