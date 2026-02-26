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
            guard case let .chooseBits(min, max, _, isRangeExplicit) = op,
                  isRangeExplicit
            else {
                return nil
            }
            return min ... max
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
        backward: @escaping (NewOutput) throws -> Value,
    ) rethrows -> ReflectiveGenerator<NewOutput> {
        try Gen.contramap(backward, map(forward))
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
        backward: some PartialPath<NewOutput, Value>,
    ) rethrows -> ReflectiveGenerator<NewOutput> {
        let erasedBackward: (Any) throws -> Any = { newOutput in
            try backward.extract(from: newOutput)!
        }
        let erasedGen = try map(forward)

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
        backward: some PartialPath<NewOutput, Value>,
    ) throws -> ReflectiveGenerator<NewOutput?> {
        let erasedBackward: (Any) throws -> Any = { newOutput in
            // FIXME: Should we be force unwrapping here? What if it's optional?
            try backward.extract(from: newOutput)!
        }
        let erasedGen = try map { try forward.extract(from: $0) }

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
                if let optional = result as? Value?, optional == nil {
                    throw Interpreters.ReflectionError.reflectedNil(type: description, resultType: String(describing: type(of: result)))
                }
                return result as! Value
            },
            next: erase(),
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

    /// Creates a filtered generator that only produces values satisfying a predicate.
    ///
    /// The filter combinator supports two strategies for satisfying the predicate,
    /// selectable via the `type` parameter:
    ///
    /// - ``FilterType/reject``: Pure rejection sampling — generate values and discard
    ///   those that fail the predicate. Simple and predictable, but inefficient when
    ///   valid values are sparse.
    /// - ``FilterType/tune``: Probes each branching point's choices through the
    ///   continuation pipeline to measure predicate satisfaction rates, then biases
    ///   weights toward valid outputs before generation begins. More expensive upfront,
    ///   but dramatically reduces rejection attempts for structurally constrained
    ///   generators.
    /// - ``FilterType/auto`` (default): Selects a strategy based on generator structure.
    ///   Uses ``FilterType/tune`` when the generator contains branching points,
    ///   otherwise falls back to ``FilterType/reject``.
    ///
    /// Both strategies maintain deterministic behaviour — given the same seed, the
    /// generator will produce the same sequence of values.
    ///
    /// ```swift
    /// // Auto strategy (default) — tunes if branching points are present
    /// let balancedBST = BinaryTree.arbitrary
    ///     .filter { $0.isBalanced && $0.satisfiesBSTProperty }
    ///
    /// // Explicit rejection sampling
    /// let positive = Gen.choose(in: Int.min...Int.max)
    ///     .filter(.reject) { $0 > 0 }
    /// ```
    ///
    /// - Parameters:
    ///   - type: Strategy for satisfying the predicate. Defaults to ``FilterType/auto``.
    ///   - predicate: Validity condition that generated values must satisfy.
    /// - Returns: A filtered generator that only produces valid values.
    @inlinable
    func filter(
        _ type: FilterType = .auto,
        _ predicate: @escaping (Value) -> Bool,
        fileID: String = #fileID,
        line: UInt = #line
    ) -> ReflectiveGenerator<Value> {
        let fingerprint = fileID.hashValue.bitPattern64 &+ line.bitPattern64

        return .impure(
            operation: .filter(gen: erase(), fingerprint: fingerprint, filterType: type, predicate: { value in predicate(value as! Value) }),
            continuation: { .pure($0 as! Value) }
        )
    }

    /// Creates a generator that only produces unique values, deduplicated by choice sequence.
    ///
    /// Each generated value's underlying choice sequence is tracked. If a duplicate
    /// choice sequence is encountered, the generator retries (up to `maxFilterRuns`
    /// from the interpreter context). This is useful when the generator's domain is
    /// large but you want to avoid repeating the same random path.
    ///
    /// - Parameters:
    ///   - fileID: Source file identifier for fingerprinting (auto-captured).
    ///   - line: Source line number for fingerprinting (auto-captured).
    /// - Returns: A generator that only yields values with unique choice sequences.
    @inlinable
    func unique(
        fileID: String = #fileID,
        line: UInt = #line
    ) -> ReflectiveGenerator<Value> {
        let fingerprint = fileID.hashValue.bitPattern64 &+ line.bitPattern64

        return .impure(
            operation: .unique(gen: erase(), fingerprint: fingerprint, keyExtractor: nil),
            continuation: { .pure($0 as! Value) }
        )
    }

    /// Creates a generator that only produces unique values, deduplicated by a key path.
    ///
    /// The value at the given key path is used as the deduplication key. Two values
    /// are considered duplicates if they produce the same key.
    ///
    /// - Parameters:
    ///   - keyPath: A key path to the hashable property used for deduplication.
    ///   - fileID: Source file identifier for fingerprinting (auto-captured).
    ///   - line: Source line number for fingerprinting (auto-captured).
    /// - Returns: A generator that only yields values with unique keys.
    @inlinable
    func unique<Key: Hashable>(
        by keyPath: KeyPath<Value, Key>,
        fileID: String = #fileID,
        line: UInt = #line
    ) -> ReflectiveGenerator<Value> {
        unique(by: { $0[keyPath: keyPath] }, fileID: fileID, line: line)
    }

    /// Creates a generator that only produces unique values, deduplicated by a transform.
    ///
    /// The transform function extracts a hashable key from each generated value.
    /// Two values are considered duplicates if they produce the same key.
    ///
    /// - Parameters:
    ///   - transform: A function that extracts a hashable key from the generated value.
    ///   - fileID: Source file identifier for fingerprinting (auto-captured).
    ///   - line: Source line number for fingerprinting (auto-captured).
    /// - Returns: A generator that only yields values with unique keys.
    @inlinable
    func unique<Key: Hashable>(
        by transform: @escaping (Value) -> Key,
        fileID: String = #fileID,
        line: UInt = #line
    ) -> ReflectiveGenerator<Value> {
        let fingerprint = fileID.hashValue.bitPattern64 &+ line.bitPattern64

        return .impure(
            operation: .unique(gen: erase(), fingerprint: fingerprint, keyExtractor: { value in AnyHashable(transform(value as! Value)) }),
            continuation: { .pure($0 as! Value) }
        )
    }

    @inlinable
    func compose<OtherValue>(with other: ReflectiveGenerator<OtherValue>) -> ReflectiveGenerator<(Value, OtherValue)> {
        Gen.zip(self, other)
    }

    // Transforms the operation type of this generator while preserving the value type.
    //
    // **Warning**: This operation has significant performance overhead as it must traverse
    // and rebuild the entire generator structure. Use sparingly and prefer type-safe alternatives.
    //
    // This is an internal utility for advanced generator transformations that need to change
    // the underlying operation type (e.g., wrapping `ReflectiveOperation` in a larger operation type).
    //
    // The transformation is applied recursively to all operations in the generator tree,
    // requiring a complete structural traversal.
    //
    // - Parameter transform: Function to convert operations to the new operation type
    // - Returns: An equivalent generator with transformed operation type
    // - Note: Marked private due to performance concerns and specialized use cases
    #warning("Not currently used anywhere. Possibly for CGS adaptation? Computationally expensive!")
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
