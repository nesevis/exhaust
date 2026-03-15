import ExhaustCore

// MARK: - Academic Provenance

// The bidirectional combinators `mapped(forward:backward:)` and `bound(forward:backward:)` implement the `comap` annotation pattern from partial monadic profunctors (Xia et al., "Composing Bidirectional Programs Monadically", ESOP 2019). At each monadic bind site, the backward function `(B) -> A` provides the contravariant annotation that aligns the forward and backward interpretations — Goldstein §4.3.1 calls this "focusing on a part of the b that contains an a". `mapped` pairs `contramap(backward)` with an invisible `_map(forward)`; `bound` reifies the pair as a `.transform(.bind)` so interpreters can see through it.

public extension ReflectiveGenerator where Operation == ReflectiveOperation {
    /// Creates a bidirectional transformation of this generator using forward and backward functions.
    /// Note that ``#gen`` with a closure will attempt to synthesize the backward mapping during macro expansion.
    ///
    /// This is the fundamental operation for adapting generators to work with different types while preserving the bidirectional capability. Both directions must be provided:
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
        forward: @Sendable @escaping (Value) throws -> NewOutput,
        backward: @Sendable @escaping (NewOutput) throws -> Value,
    ) rethrows -> ReflectiveGenerator<NewOutput> {
        try Gen.contramap(backward, _map(forward))
    }

    /// Creates a bidirectional transformation using a forward function and a partial path for backward.
    ///
    /// This overload uses a `PartialPath` for the backward transformation, which can fail gracefully when the reflection target doesn't contain the expected structure. If extraction fails, that reflection branch is pruned.
    ///
    /// - Parameters:
    ///   - forward: Function to transform generated values
    ///   - backward: Partial path to extract the original value from the new type
    /// - Returns: A generator producing values of the new output type
    /// - Throws: Rethrows errors from the forward transformation
    @inlinable
    func mapped<NewOutput>(
        forward: @Sendable @escaping (Value) throws -> NewOutput,
        backward: some PartialPath<NewOutput, Value>,
    ) rethrows -> ReflectiveGenerator<NewOutput> {
        let erasedBackward: (Any) throws -> Any = { newOutput in
            try backward.extract(from: newOutput)!
        }
        let erasedGen = try _map(forward)

        return Gen.contramap(erasedBackward, erasedGen)
    }

    /// Creates a bidirectional transformation using partial paths in both directions.
    ///
    /// This overload uses partial paths for both transformations, making both directions potentially fallible. When either direction fails, that branch is pruned.
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
        let erasedGen = try _map { try forward.extract(from: $0) }

        return Gen.contramap(erasedBackward, erasedGen)
    }

    /// Creates a bidirectional transformation using a partial path for forward and a function for backward.
    ///
    /// This overload uses a `PartialPath` for the forward transformation and a closure for the backward direction. The result type is optional because the forward path extraction may not match.
    ///
    /// - Parameters:
    ///   - forward: Partial path to transform from original to new type
    ///   - backward: Function to transform back during reflection
    /// - Returns: A generator producing optional values of the new type
    /// - Throws: Errors from path extraction during setup
    @inlinable
    func mapped<NewOutput>(
        forward: some PartialPath<Value, NewOutput>,
        backward: @Sendable @escaping (NewOutput) throws -> Value,
    ) throws -> ReflectiveGenerator<NewOutput?> {
        let erasedBackward: (Any) throws -> Any = { try backward($0 as! NewOutput) }
        let erasedGen = try _map { try forward.extract(from: $0) }

        return Gen.contramap(erasedBackward, erasedGen)
    }

    /// Transforms generated values through a partial path, producing optional results.
    ///
    /// Applies the partial path's extraction to each generated value. Since extraction may fail (e.g. a case path that doesn't match), the result type is optional.
    ///
    /// - Parameter path: Partial path to extract the new value from the generated value
    /// - Returns: A generator producing optional values of the extracted type
    @inlinable
    func map<NewOutput>(
        _ path: some PartialPath<Value, NewOutput>,
    ) throws -> ReflectiveGenerator<NewOutput?> {
        Gen.liftF(.transform(
            kind: .map(
                forward: { try path.extract(from: $0) as Any },
                inputType: String(describing: Value.self),
                outputType: String(describing: NewOutput.self),
            ),
            inner: erase(),
        ))
    }

    /// Converts this generator to produce optional values, enabling nil/non-nil choice patterns.
    ///
    /// This transformation is essential for generators that need to handle optional types or work with nullable fields. During reflection, it properly handles the distinction between `.none` and `.some(value)` cases.
    ///
    /// **Reflection behavior**: When reflecting on `nil`, throws `ReflectionError.reflectedNil` to signal that the non-optional branch should be pruned. When reflecting on `.some(value)`, extracts the wrapped value for the underlying generator to reflect on.
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

    /// Categorizes generated values for statistical analysis.
    ///
    /// Wraps this generator with classification predicates that track how frequently different types of test data are generated.
    ///
    /// ```swift
    /// let classified = #gen(.int(in: 0...100)).classify(
    ///     ("small", { $0 < 10 }),
    ///     ("large", { $0 > 90 })
    /// )
    /// ```
    @inlinable
    func classify(
        _ classifiers: (String, @Sendable (Value) -> Bool)...,
    ) -> ReflectiveGenerator<Value> {
        .impure(operation:
            .classify(
                gen: erase(),
                fingerprint: 0,
                classifiers: classifiers.map { pair in (pair.0, { pair.1($0 as! Value) }) },
            )) { .pure($0 as! Value) }
    }

    /// Runs this generator with a temporarily modified size parameter.
    ///
    /// ```swift
    /// let small = #gen(.int().array()).resize(10)
    /// ```
    @inlinable
    func resize(_ newSize: UInt64) -> ReflectiveGenerator<Value> {
        Gen.liftF(.resize(newSize: newSize, next: erase()))
    }

    /// Creates a filtered generator that only produces values satisfying a predicate.
    ///
    /// The filter combinator supports several strategies for satisfying the predicate, selectable via the `type` parameter:
    ///
    /// - ``FilterType/rejectionSampling``: Pure rejection sampling — generate values and discard those that fail the predicate. Simple and predictable, but inefficient when valid values are sparse.
    /// - ``FilterType/probeSampling``: Probes each branching point's choices through the continuation pipeline to measure predicate satisfaction rates, then biases weights toward valid outputs before generation begins.
    /// - ``FilterType/choiceGradientSampling``: Runs a CGS (Choice Gradient Sampling) warmup pass to learn pick weights conditioned on upstream choices, then bakes them with fitness sharing to prevent overcommitting to the dominant cluster. Produces the best balance of validity rate and output diversity for recursive generators like BST/AVL. Incurs a slight penalty for generators with few branching points.
    /// - ``FilterType/auto`` (default): Uses ``FilterType/choiceGradientSampling``.
    ///
    /// All strategies maintain deterministic behavior — given the same seed, the generator will produce the same sequence of values.
    ///
    /// ```swift
    /// // Auto strategy (default) — in this case uses .choiceGradientSampling
    /// let balancedBST = #gen(myBSTGen)
    ///     .filter { $0.isValid }
    ///
    /// // Explicit rejection sampling
    /// let positive = #gen(.int(in: .min ... .max))
    ///     .filter(.rejectionSampling) { $0 > 0 }
    /// ```
    ///
    /// - Parameters:
    ///   - type: Strategy for satisfying the predicate. Defaults to ``FilterType/auto``.
    ///   - predicate: Validity condition that generated values must satisfy.
    /// - Returns: A filtered generator that only produces valid values.
    @inlinable
    func filter(
        _ type: FilterType = .auto,
        _ predicate: @Sendable @escaping (Value) -> Bool,
        fileID: String = #fileID,
        line: UInt = #line,
    ) -> ReflectiveGenerator<Value> {
        let fingerprint = fileID.hashValue.bitPattern64 &+ line.bitPattern64

        return .impure(
            operation: .filter(gen: erase(), fingerprint: fingerprint, filterType: type, predicate: { value in predicate(value as! Value) }),
            continuation: { .pure($0 as! Value) },
        )
    }

    /// Creates a generator that only produces unique values, deduplicated by choice sequence.
    ///
    /// Each generated value's underlying choice sequence is tracked. If a duplicate choice sequence is encountered, the generator retries (up to `maxFilterRuns` from the interpreter context). This is useful when the generator's domain is large but you want to avoid repeating the same random path.
    ///
    /// Unlike `.filter`, `.unique` does not trigger ``FilterType/choiceGradientSampling`` tuning of the inner generator, because the deduplication predicate is stateful (it depends on what has been seen so far) and cannot be learned during a warmup pass. If `.unique()` is slow or exhausts its retry budget, the inner generator likely has a sparse validity condition that should be made explicit.
    /// Apply `.filter` *before* `.unique` so that the choice-gradient tuner can learn the static predicate and bias pick weights toward valid outputs:
    ///
    /// ```swift
    /// // Slow — .unique() retries blindly against a sparse validity space
    /// #gen(.binaryTree()).unique()
    ///
    /// // Fast — .filter() triggers .choiceGradientSampling, then .unique() deduplicates
    /// #gen(.binaryTree())
    ///     .filter { $0.isValidBST() }
    ///     .unique()
    /// ```
    ///
    /// - Parameters:
    ///   - fileID: Source file identifier for fingerprinting (auto-captured).
    ///   - line: Source line number for fingerprinting (auto-captured).
    /// - Returns: A generator that only yields values with unique choice sequences.
    @inlinable
    func unique(
        fileID: String = #fileID,
        line: UInt = #line,
    ) -> ReflectiveGenerator<Value> {
        let fingerprint = fileID.hashValue.bitPattern64 &+ line.bitPattern64

        return .impure(
            operation: .unique(gen: erase(), fingerprint: fingerprint, keyExtractor: nil),
            continuation: { .pure($0 as! Value) },
        )
    }

    /// Creates a generator that only produces unique values, deduplicated by a key path.
    ///
    /// The value at the given key path is used as the deduplication key. Two values are considered duplicates if they produce the same key.
    ///
    /// - Parameters:
    ///   - keyPath: A key path to the hashable property used for deduplication.
    ///   - fileID: Source file identifier for fingerprinting (auto-captured).
    ///   - line: Source line number for fingerprinting (auto-captured).
    /// - Returns: A generator that only yields values with unique keys.
    @inlinable
    func unique(
        by keyPath: KeyPath<Value, some Hashable & Sendable>,
        fileID: String = #fileID,
        line: UInt = #line,
    ) -> ReflectiveGenerator<Value> {
        nonisolated(unsafe) let keyPath = keyPath
        return unique(by: { $0[keyPath: keyPath] }, fileID: fileID, line: line)
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
    func unique(
        by transform: @Sendable @escaping (Value) -> some Hashable,
        fileID: String = #fileID,
        line: UInt = #line,
    ) -> ReflectiveGenerator<Value> {
        let fingerprint = fileID.hashValue.bitPattern64 &+ line.bitPattern64

        return .impure(
            operation: .unique(gen: erase(), fingerprint: fingerprint, keyExtractor: { value in AnyHashable(transform(value as! Value)) }),
            continuation: { .pure($0 as! Value) },
        )
    }

    /// Creates a recursive generator with a constant base case value.
    ///
    /// The `extend` closure receives a `recurse` thunk and a `remaining` depth budget that counts down from `maxDepth` (outermost) to 1 (innermost). To terminate early, return a generator that doesn't call `recurse()` — this short-circuits the recursion since inner layers are only reachable through `recurse()`.
    ///
    /// ```swift
    /// .recursive(base: .leaf, maxDepth: 5) { recurse, remaining in
    ///     guard remaining > 1 else { return .just(.leaf) }
    ///     .oneOf(weighted:
    ///         (1, .just(.leaf)),
    ///         (Int(remaining), #gen(recurse(), .uint(in: 0...9), recurse()).map { .node($0, $1, $2) })
    ///     )
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - base: The ground value used when recursion bottoms out
    ///   - maxDepth: Maximum number of recursive layers to unfold
    ///   - extend: Closure that builds one recursive layer from the previous layer
    /// - Returns: A generator that produces recursive values with depth-controlled structure
    static func recursive(
        base: Value,
        maxDepth: UInt64,
        extend: @Sendable @escaping (@escaping () -> ReflectiveGenerator<Value>, UInt64) -> ReflectiveGenerator<Value>,
    ) -> ReflectiveGenerator<Value> {
        Gen.recursive(base: base, maxDepth: maxDepth, extend: extend)
    }

    /// Creates a recursive generator with a generator base case.
    ///
    /// Use this overload when the base case itself needs randomness (e.g. random leaf values).
    ///
    /// The `extend` closure receives a `recurse` thunk and a `remaining` depth budget that counts down from `maxDepth` (outermost) to 1 (innermost). To terminate early, return a generator that doesn't call `recurse()` — this short-circuits the recursion since inner layers are only reachable through `recurse()`.
    ///
    /// ```swift
    /// let baseGen = Gen.choose(in: 0...9).map { Expression.literal($0) }
    /// .recursive(base: baseGen, maxDepth: 4) { recurse, remaining in
    ///     .oneOf(weighted:
    ///         (1, baseGen),
    ///         (Int(remaining), #gen(recurse(), recurse()).map { .add($0, $1) })
    ///     )
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - base: Generator for the base case
    ///   - maxDepth: Maximum number of recursive layers to unfold
    ///   - extend: Closure that builds one recursive layer from the previous layer
    /// - Returns: A generator that produces recursive values with depth-controlled structure
    static func recursive(
        base: ReflectiveGenerator<Value>,
        maxDepth: UInt64,
        extend: @Sendable @escaping (@escaping () -> ReflectiveGenerator<Value>, UInt64) -> ReflectiveGenerator<Value>,
    ) -> ReflectiveGenerator<Value> {
        Gen.recursive(base: base, maxDepth: maxDepth, extend: extend)
    }

    /// Retrieves the current size parameter controlling generator complexity.
    ///
    /// The size parameter ranges from 1–100 and controls how complex generated values should be. Use this to build generators that adapt to the testing phase.
    ///
    /// ```swift
    /// let adaptiveArray = ReflectiveGenerator.getSize().bind { size in
    ///     .int(in: 0...Int(size)).array(length: 0...Int(size))
    /// }
    /// ```
    static func getSize() -> ReflectiveGenerator<UInt64> {
        Gen.getSize()
    }

    // MARK: - Functor & Monad

    /// Transforms the generated value using a pure function.
    ///
    /// Use `map` when you want to convert the output type without introducing additional generator structure. The transformation is applied after generation.
    ///
    /// ```swift
    /// let lengths = #gen(.asciiString()).map { $0.count }
    /// ```
    ///
    /// - Parameter transform: A function to apply to each generated value
    /// - Returns: A generator producing the transformed values
    @inlinable
    func map<NewValue>(_ transform: @Sendable @escaping (Value) throws -> NewValue) rethrows -> ReflectiveGenerator<NewValue> {
        Gen.liftF(.transform(
            kind: .map(
                forward: { try transform($0 as! Value) },
                inputType: String(describing: Value.self),
                outputType: String(describing: NewValue.self),
            ),
            inner: erase(),
        ))
    }

    /// Chains this generator with a dependent generator.
    ///
    /// Use `bind` when the next generator depends on the value produced by this one.
    /// This is more powerful than `map` but **breaks reflection** — the backward pass cannot see through the dependency, so test case reduction will not work through `bind` chains.
    ///
    /// Prefer `map`, `zip`, or `#gen(a, b) { ... }` when possible. Use `bind` only when you genuinely need dependent generation.
    ///
    /// ```swift
    /// let dependentArray = #gen(.int(in: 1...10)).bind { n in
    ///     Gen.arrayOf(Gen.choose(in: 0...n), exactly: UInt64(n))
    /// }
    /// ```
    ///
    /// - Parameter transform: A function that takes the generated value and returns a new generator
    /// - Returns: A generator that sequences the two computations
    @inlinable
    func bind<NewValue>(_ transform: @Sendable @escaping (Value) throws -> ReflectiveGenerator<NewValue>) rethrows -> ReflectiveGenerator<NewValue> {
        Gen.liftF(.transform(
            kind: .bind(
                forward: { try transform($0 as! Value).erase() },
                backward: nil,
                inputType: String(describing: Value.self),
                outputType: String(describing: NewValue.self),
            ),
            inner: erase(),
        ))
    }

    /// Chains this generator with a dependent generator, with a backward extraction function for reflection.
    ///
    /// This is the bind-level analogue of ``mapped(forward:backward:)``. The `backward` function
    /// extracts the inner generator's input from the final output, enabling reflection (and therefore
    /// shrinking) through the bind.
    ///
    /// - **Forward**: Takes the inner value `A` and returns a dependent generator over `B`
    /// - **Backward**: Extracts `A` from a `B` — the `comap` annotation at bind sites (Xia et al. ESOP 2019)
    ///
    /// ```swift
    /// let sized = #gen(.int(in: 1...10)).bound(
    ///     forward: { n in .string(length: n) },
    ///     backward: { str in str.count }
    /// )
    /// ```
    ///
    /// - Parameters:
    ///   - forward: Function that takes the generated value and returns a new generator
    ///   - backward: Function that extracts the inner value from the final output
    /// - Returns: A generator that sequences the two computations with bidirectional support
    @inlinable
    func bound<NewValue>(
        forward: @Sendable @escaping (Value) throws -> ReflectiveGenerator<NewValue>,
        backward: @Sendable @escaping (NewValue) throws -> Value,
    ) rethrows -> ReflectiveGenerator<NewValue> {
        try _bound(forward: forward, backward: backward)
    }

    /// Chains this generator with a dependent generator, using a partial path for backward extraction.
    ///
    /// This overload uses a `PartialPath` for the backward transformation, which can fail gracefully
    /// when the reflection target doesn't contain the expected structure. If extraction fails,
    /// that reflection branch is pruned.
    ///
    /// - Parameters:
    ///   - forward: Function that takes the generated value and returns a new generator
    ///   - backward: Partial path to extract the inner value from the final output
    /// - Returns: A generator that sequences the two computations with bidirectional support
    @inlinable
    func bound<NewValue>(
        forward: @Sendable @escaping (Value) throws -> ReflectiveGenerator<NewValue>,
        backward: some PartialPath<NewValue, Value>,
    ) rethrows -> ReflectiveGenerator<NewValue> {
        try _bound(forward: forward, backward: { try backward.extract(from: $0)! })
    }
}
