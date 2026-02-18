/// The primitive operations that enable bidirectional property-based testing.
///
/// ReflectiveOperation defines the fundamental operations that make reflective generators bidirectional.
/// Each operation can be interpreted in **three ways**:
///
/// ## Forward Pass (Generation)
/// Operations consume randomness to produce values:
/// - `chooseBits`: Generates random UInt64 within range
/// - `pick`: Selects one choice based on weights
/// - `sequence`: Builds arrays by repeated element generation
/// - `contramap`/`prune`: Transform or filter the input context
///
/// ## Backward Pass (Reflection)
/// Operations analyze values to discover which random choices could have produced them:
/// - `chooseBits`: Checks if value's bit pattern falls within range
/// - `pick`: Tries all choices against the target value
/// - `sequence`: Decomposes arrays into element-by-element reflection paths
/// - `contramap`/`prune`: Transforms target through lens or checks validity
///
/// ## Replay Pass (Deterministic Recreation)
/// Operations consume pre-recorded choices to recreate exact values:
/// - `chooseBits`: Uses recorded bit pattern from choice tree
/// - `pick`: Follows recorded branch selection
/// - `sequence`: Replays each element using recorded sub-trees
/// - `contramap`/`prune`: Passes through recorded decisions
///
/// ## Architecture
///
/// Operations use type erasure (`Any`) because Swift enums cannot change generic parameters
/// across cases. The FreerMonad continuation handles type-safe conversion back to the expected
/// output type, enabling the separation of effect description from interpretation.
///
/// **Construction**: Operations are created by `Gen` combinators and interpreted by `Interpreters`.
/// Never construct directly.
///
/// - SeeAlso: `ReflectiveGenerator`, `Gen`, `Interpreters`
public enum ReflectiveOperation {
    /// A weighted choice option for the `pick` operation.
    ///
    /// Each choice combines the elements needed for bidirectional generation:
    /// - **id**: Stable branch identifier used for deterministic replay/materialization
    /// - **weight**: Probability mass for random selection during generation
    /// - **generator**: The sub-generator to execute if this choice is selected
    public struct PickTuple {
        public let id: UInt64
        public let weight: UInt64
        public let generator: ReflectiveGenerator<Any>

        public init(
            id: UInt64,
            weight: UInt64,
            generator: ReflectiveGenerator<Any>,
        ) {
            self.id = id
            self.weight = weight
            self.generator = generator
        }
    }
    /// Contravariant transformation that focuses on part of the input during reflection.
    ///
    /// This is the key operation that enables generators to work with different input types
    /// while maintaining bidirectional capabilities. The transform function acts as a "lens"
    /// that extracts the relevant portion of data during reflection.
    ///
    /// **Forward pass**: Transform is ignored - generation proceeds with current context
    /// **Backward pass**: Transform extracts the focus area from the target value
    /// **Replay pass**: Transform processes the replayed input context
    ///
    /// **Failure handling**: If transform returns `nil`, that reflection branch is pruned.
    /// This enables conditional generation based on input structure.
    ///
    /// - Parameters:
    ///   - transform: Function that extracts focus area, returning nil to prune branches
    ///   - next: Generator to apply to the extracted input
    case contramap(transform: (Any) throws -> Any?, next: ReflectiveGenerator<Any>)

    /// Weighted random choice between multiple generation strategies.
    ///
    /// This operation enables probabilistic generation where different outcomes have different
    /// likelihoods. It's the foundation for building complex generators from simpler components.
    ///
    /// **Forward pass**: Randomly selects one choice based on relative weights
    /// **Backward pass**: **Key insight** - tries ALL choices against target value to find matches
    /// **Replay pass**: Uses recorded branch id to deterministically select the same branch
    ///
    /// **Performance note**: ContiguousArray provides better cache locality than Array for
    /// frequent iteration during reflection.
    ///
    /// - Parameter choices: Array of weighted generator options with replay labels
    case pick(choices: ContiguousArray<PickTuple>)

    /// Conditional generation that prunes invalid branches during reflection.
    ///
    /// This operation works with `contramap` to handle cases where the input transformation
    /// might fail. When a preceding `contramap` returns `nil`, `prune` eliminates that
    /// reflection path, focusing the search on valid branches.
    ///
    /// **Forward pass**: If input context is invalid (nil), generation fails gracefully
    /// **Backward pass**: Unwraps valid input and continues reflection with nested generator
    /// **Replay pass**: Passes through recorded valid inputs
    ///
    /// **Why separate from contramap**: This separation allows interpreters to handle
    /// failure cases explicitly, enabling different strategies for invalid branches.
    ///
    /// - Parameter next: Generator to apply if the input is valid (non-nil)
    case prune(next: ReflectiveGenerator<Any>)

    /// Primitive random bit pattern generation within a bounded range.
    ///
    /// This is the fundamental randomness operation that underlies all bounded value generation.
    /// By working at the bit pattern level, it provides a unified interface for generating
    /// any `BitPatternConvertible` type with proper reflection support.
    ///
    /// **Forward pass**: Generates random UInt64 between min and max (inclusive)
    /// **Backward pass**: Checks if target value's bit pattern falls within [min, max]
    /// **Replay pass**: Uses recorded bit pattern from choice tree
    ///
    /// **Type handling**: The `TypeTag` enables type-specific interpretation:
    /// - `Int`: Bit pattern represents signed integer
    /// - `Float`: Bit pattern represents IEEE 754 floating point
    /// - `Character`: Bit pattern represents Unicode scalar value
    /// - `Bool`: Bit pattern 0 = false, 1 = true
    ///
    /// **Uniformity**: The bit-level approach ensures uniform distribution across the
    /// specified range, avoiding bias that can occur with modular arithmetic.
    ///
    /// - Parameters:
    ///   - min: Minimum bit pattern value (inclusive)
    ///   - max: Maximum bit pattern value (inclusive)
    ///   - tag: Type tag for proper interpretation of bit patterns
    case chooseBits(min: UInt64, max: UInt64, tag: TypeTag)

    /// Stack-safe sequence generation for creating arrays and collections.
    ///
    /// This operation enables the generation of variable-length collections without
    /// recursive bind chains that could cause stack overflow. It's the foundation
    /// for `Gen.arrayOf` and similar collection generators.
    ///
    /// **Forward pass**:
    /// 1. Generate length using the length generator
    /// 2. Apply element generator `length` times iteratively
    /// 3. Collect results into an array
    ///
    /// **Backward pass**:
    /// 1. Reflect on target array length to get possible length values
    /// 2. For each element, reflect using the element generator
    /// 3. Combine all element reflection paths with length paths
    ///
    /// **Replay pass**:
    /// 1. Replay length from choice tree
    /// 2. Replay each element using corresponding sub-trees
    /// 3. Reconstruct the exact original array
    ///
    /// **Stack safety**: Unlike recursive monadic composition, this operation
    /// is interpreted iteratively by the interpreter, avoiding deep call stacks
    /// for large collections.
    ///
    /// - Parameters:
    ///   - length: Generator that determines the sequence length
    ///   - gen: Generator applied to each element position
    case sequence(length: ReflectiveGenerator<UInt64>, gen: ReflectiveGenerator<Any>)

    /// Parallel composition of multiple generators into a tuple result.
    ///
    /// This operation enables clean composition of multiple generators without deeply
    /// nested monadic bind chains ("pyramid of doom"). It's essential for building
    /// generators that combine several independent random choices.
    ///
    /// **Forward pass**: Generates values from all generators and combines into tuple
    /// **Backward pass**: Decomposes target tuple and reflects each component independently
    /// **Replay pass**: Replays all generators using corresponding choice sub-trees
    ///
    /// **Performance**: ContiguousArray provides better cache locality than Array
    /// when iterating through generators during interpretation.
    ///
    /// **Type erasure**: All generators are erased to `ReflectiveGenerator<Any>`
    /// because Swift enums cannot store heterogeneous generic types. The interpreter
    /// handles type-safe reconstruction of the final tuple.
    ///
    /// - Parameter generators: Array of generators to compose in parallel
    case zip(ContiguousArray<ReflectiveGenerator<Any>>)

    /// Produces a constant value without consuming any randomness.
    ///
    /// This is the simplest operation - it always produces the same predetermined value.
    /// It's the foundation for `Gen.just` and serves as the identity element for
    /// generator composition.
    ///
    /// **Forward pass**: Always returns the stored constant value
    /// **Backward pass**: Succeeds if target equals the constant, fails otherwise
    /// **Replay pass**: Always returns the constant (no choices to replay)
    ///
    /// **Use cases**:
    /// - Default values in choice generators
    /// - Fixed components in composite generators
    /// - Base case for recursive generators
    ///
    /// **Type erasure**: Value stored as `Any` due to enum constraints.
    /// The containing generator's continuation handles type-safe casting.
    ///
    /// - Parameter value: The constant value to always produce
    case just(Any)

    /// Accesses the current size parameter for complexity-scaled generation.
    ///
    /// The size parameter is fundamental to property-based testing - it controls how
    /// complex generated values should be. Size typically starts small and grows as
    /// tests progress, enabling simple counterexamples to be found before complex ones.
    ///
    /// **Forward pass**: Returns the interpreter's current size parameter
    /// **Backward pass**: Returns a fixed size (often derived from target complexity)
    /// **Replay pass**: Returns the recorded size from when the choice tree was created
    ///
    /// **Size scaling examples**:
    /// - Arrays: Length scales with size (larger arrays in later tests)
    /// - Trees: Depth scales with size (deeper trees in later tests)
    /// - Strings: Length scales with size (longer strings in later tests)
    /// - Numeric ranges: May use size to set bounds
    ///
    /// **Reflection implications**: During reflection, size represents the complexity
    /// of the target value being analyzed, helping guide the search through possible
    /// generation paths.
    ///
    /// - Returns: Current size parameter as UInt64
    case getSize

    /// Temporarily overrides the size parameter for a nested generator scope.
    ///
    /// This operation enables fine-grained control over generation complexity by
    /// setting a specific size for part of the generator tree. The size change
    /// is scoped - it only affects the nested generator and its descendants.
    ///
    /// **Forward pass**: Sets new size, runs nested generator, then restores original size
    /// **Backward pass**: Runs nested generator with the specified size context
    /// **Replay pass**: Maintains size override during replay of nested generator
    ///
    /// **Common use cases**:
    /// - Prevent exponential growth in recursive generators
    /// - Fixed-size components regardless of overall size
    /// - Size-independent testing with small inputs
    ///
    /// **Scoping**: Size changes don't leak beyond the nested generator.
    /// After completion, the original size parameter is automatically restored.
    ///
    /// - Parameters:
    ///   - newSize: Temporary size parameter for the nested scope
    ///   - next: Generator to run with the modified size
    case resize(newSize: UInt64, next: ReflectiveGenerator<Any>)

    /// Identifies generators with validity conditions that can be optimized.
    ///
    /// This operation marks generators that have specific validity requirements or preconditions
    /// that make them candidates for optimization through Choice Gradient Sampling (CGS) or
    /// rejection sampling. The filter operation enables the framework to automatically detect
    /// and improve generators that would otherwise waste computational resources on invalid inputs.
    ///
    /// **Forward pass**: Generates values using the wrapped generator and validates them with the predicate
    /// **Backward pass**: Only reflects on values that satisfy the predicate condition
    /// **Replay pass**: Replays the wrapped generator if the recorded choice satisfied the predicate
    ///
    /// **CGS Optimization**: When a `filter` operation is detected, the Choice Gradient Sampling
    /// system can analyze which random choices lead to predicate satisfaction. This enables
    /// automatic bias adjustment to increase the proportion of valid outputs without manual
    /// generator tuning.
    ///
    /// **Rejection Sampling Fallback**: For generators that aren't suitable for CGS optimization,
    /// the filter serves as a signal to use rejection sampling, generating candidates until
    /// the predicate is satisfied.
    ///
    /// **Fingerprint**: The fingerprint parameter provides a unique identifier for the specific
    /// validity condition, enabling the optimization system to cache learned gradients and
    /// apply them across different generator instances with the same logical constraints.
    ///
    /// **Use cases**:
    /// - Balanced binary search trees (structural validity)
    /// - Valid email addresses (format constraints)
    /// - Non-empty collections (size constraints)
    /// - Mathematical invariants (value relationships)
    ///
    /// - Parameters:
    ///   - gen: The base generator to filter
    ///   - fingerprint: Unique identifier for this filter condition (for optimization caching)
    ///   - predicate: Validity condition that generated values must satisfy
    case filter(gen: ReflectiveGenerator<Any>, fingerprint: UInt64, predicate: (Any) -> Bool)

    /// Categorizes generated values for statistical analysis and test coverage reporting.
    ///
    /// This operation enables developers to understand the distribution of generated test data
    /// by applying labeled predicates to each generated value. The framework automatically
    /// collects statistics and reports percentages when testing completes.
    ///
    /// **Forward pass**: Generates values normally while testing against all classifiers
    /// **Backward pass**: Reflects normally (classification doesn't affect reflection)
    /// **Replay pass**: Replays normally (classification is analysis, not generation)
    ///
    /// **Statistical reporting**: When test execution reaches `maxRuns`, the interpreter
    /// automatically prints distribution statistics showing what percentage of generated
    /// values satisfied each classifier, enabling developers to verify test coverage and
    /// identify generator bias.
    ///
    /// **Use cases**:
    /// - Debug generator coverage: "Am I generating edge cases?"
    /// - Verify test quality: "Are tests exercising the scenarios I care about?"
    /// - Tune generator weights: "Should I adjust probabilities?"
    ///
    /// - Parameters:
    ///   - gen: The base generator to classify
    ///   - fingerprint: Unique identifier for this classification operation
    ///   - classifiers: Array of (label, predicate) pairs for categorizing values
    case classify(gen: ReflectiveGenerator<Any>, fingerprint: UInt64, classifiers: [(label: String, predicate: (Any) -> Bool)])
}
