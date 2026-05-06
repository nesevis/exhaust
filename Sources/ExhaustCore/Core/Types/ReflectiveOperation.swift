// MARK: - Academic Provenance
//
// Based on the `R b a` effect type (Goldstein §4.3, Fig 4.2). The dissertation defines six primitive operations; Exhaust maps them as follows:
//
//   Dissertation      Exhaust
//   ─────────────     ─────────────
//   Pick            → pick
//   Lmap            → contramap
//   Prune           → prune
//   ChooseInteger   → chooseBits (divergence: Exhaust uses sized bit-width
//                     selection with TypeTag, not arbitrary integer ranges)
//   GetSize         → getSize
//   Resize          → resize
//
// The remaining seven cases are Exhaust extensions not present in the dissertation: `sequence`, `zip`, `just`, `filter`, `classify`, `unique`, `transform`.

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
/// ## Type Erasure Contract
///
/// Associated values use `Any` because Swift enums cannot vary generic parameters across cases. The public API never exposes this: users see only typed generators and typed closures.
///
/// Every `as!` cast in an interpreter succeeds because the ``Gen`` combinator that constructed the operation guarantees the type: the value an interpreter produces for an operation is the type that operation's continuation was built to receive. The compiler cannot verify this. If you add a case or write an interpreter, the contract is yours to uphold.
///
/// A failing cast means the interpreter produced the wrong type, or the combinator attached the wrong continuation. The fault is always internal to the framework.
///
/// **Construction**: Operations are created by ``Gen`` combinators and interpreted by ``Interpreters``. Never construct directly.
///
/// - SeeAlso: ``ReflectiveGenerator``, ``Gen``, ``Interpreters``
// MARK: - Interpretation Sites
//
// Case              Generate                      Reflect           Replay            Adapt / Analyze
// chooseBits        VACTI / VI                    Reflect.swift     Replay.swift      ChoiceTreeAnalysis
// pick              VACTI / VI                    Reflect.swift     Replay.swift      ChoiceGraphBuilder
// contramap         InterpreterWrapperHandlers    Reflect.swift     Replay.swift      (transparent)
// prune             InterpreterWrapperHandlers    Reflect.swift     Replay.swift      (transparent)
// sequence          VACTI / VI                    Reflect.swift     Replay.swift      ChoiceTreeAnalysis
// zip               VACTI / VI                    Reflect.swift     Replay.swift      ChoiceTreeAnalysis
// just              VACTI / VI                    Reflect.swift     Replay.swift      (terminal)
// getSize           VACTI / VI                    Reflect.swift     Replay.swift      (terminal)
// resize            InterpreterWrapperHandlers    Reflect.swift     Replay.swift      (transparent)
// filter            Gen+Filter / CGS pipeline     (pass-through)    (pass-through)    OnlineCGSInterpreter
// classify          InterpreterWrapperHandlers    (pass-through)    (pass-through)    (pass-through)
// unique            InterpreterWrapperHandlers    (pass-through)    (pass-through)    (pass-through)
// transform         VACTI / VI                    Reflect.swift     Replay.swift      ChoiceGraphBuilder

public enum ReflectiveOperation {
    /// A weighted choice option for the `pick` operation.
    ///
    /// Each choice combines the elements needed for bidirectional generation:
    /// - **id**: Stable branch identifier used for deterministic replay/materialization
    /// - **weight**: Probability mass for random selection during generation
    /// - **generator**: The sub-generator to execute if this choice is selected
    public struct PickTuple {
        /// Derived from the generator's structural shape. Two picks with matching fingerprints share the same recursive template at different unrolling depths: the ChoiceGraph uses this to build self-similarity edges for substitution.
        public let fingerprint: UInt64
        /// Zero-based index within the pick's branch list. Persisted in the ChoiceSequence so the materializer can select this exact branch during replay without re-running all branches.
        public let id: UInt64
        /// Relative (unnormalized) probability. During generation, the PRNG draw is partitioned proportionally across branches. During CGS tuning, weights are overridden by learned biases. Zero weight makes the branch unreachable during generation but still reachable during reflection.
        public let weight: UInt64
        /// Type-erased because Swift enums cannot vary generic parameters across cases. The pick interpreter casts the continuation result back to the expected type at each branch boundary.
        public let generator: ReflectiveGenerator<Any>

        /// Creates a pick tuple with the given fingerprint, identifier, weight, and generator.
        public init(
            fingerprint: UInt64,
            id: UInt64,
            weight: UInt64,
            generator: ReflectiveGenerator<Any>
        ) {
            self.fingerprint = fingerprint
            self.id = id
            self.weight = weight
            self.generator = generator
        }
    }

    /// Focuses the reflection target on the subpart that the inner generator can reflect on. During generation, the transform is skipped: it affects only the backward pass. During reflection, `transform` narrows the target value; when it returns `nil`, the enclosing ``prune`` eliminates that branch.
    ///
    /// - Parameters:
    ///   - transform: Function that extracts focus area, returning nil to prune branches.
    ///   - next: Generator to apply to the extracted input.
    case contramap(transform: (Any) throws -> Any?, next: ReflectiveGenerator<Any>)

    /// Weighted random choice between multiple generation strategies.
    ///
    /// This operation enables probabilistic generation where different outcomes have different likelihoods. It's the foundation for building complex generators from simpler components.
    ///
    /// **Forward pass**: Randomly selects one choice based on relative weights
    /// **Backward pass**: **Key insight** - tries ALL choices against target value to find matches
    /// **Replay pass**: Uses recorded branch id to deterministically select the same branch
    ///
    /// **Performance note**: ContiguousArray provides better cache locality than Array for frequent iteration during reflection.
    ///
    /// - Parameters:
    ///   - choices: Array of weighted generator options with replay labels.
    ///   - branchCount: The number of branches at this pick site. Branch identifiers are `0 ..< branchCount`.
    case pick(choices: ContiguousArray<PickTuple>, branchCount: UInt64)

    /// Conditional generation that prunes invalid branches during reflection.
    ///
    /// This operation works with `contramap` to handle cases where the input transformation might fail. When a preceding `contramap` returns `nil`, `prune` eliminates that reflection path, focusing the search on valid branches.
    ///
    /// **Forward pass**: If input context is invalid (nil), generation fails gracefully
    /// **Backward pass**: Unwraps valid input and continues reflection with nested generator
    /// **Replay pass**: Passes through recorded valid inputs
    ///
    /// **Why separate from contramap**: This separation allows interpreters to handle failure cases explicitly, enabling different strategies for invalid branches.
    ///
    /// - Parameter next: Generator to apply if the input is valid (non-nil).
    case prune(next: ReflectiveGenerator<Any>)

    /// Primitive random bit pattern generation within a bounded range.
    ///
    /// This is the fundamental randomness operation that underlies all bounded value generation.
    /// By working at the bit pattern level, it provides a unified interface for generating any ``BitPatternConvertible`` type with proper reflection support.
    ///
    /// **Forward pass**: Generates random UInt64 between min and max (inclusive)
    /// **Backward pass**: Checks if target value's bit pattern falls within [min, max]
    /// **Replay pass**: Uses recorded bit pattern from choice tree
    ///
    /// **Type handling**: The ``TypeTag`` enables type-specific interpretation:
    /// - `Int`: Bit pattern represents signed integer
    /// - `Float`: Bit pattern represents IEEE 754 floating point
    /// - `Character`: Bit pattern represents an index into a ``CharacterSet``
    /// - `Bool`: Bit pattern 0 = false, 1 = true
    ///
    /// **Uniformity**: The bit-level approach ensures uniform distribution across the specified range, avoiding bias that can occur with modular arithmetic.
    ///
    /// - Parameters:
    ///   - min: Minimum bit pattern value (inclusive).
    ///   - max: Maximum bit pattern value (inclusive).
    ///   - tag: Type tag for proper interpretation of bit patterns.
    ///   - isRangeExplicit: Whether `min...max` came from an explicit, stable bound that reflection should preserve and validate.
    ///   - scaling: Optional size-scaling strategy. When non-nil, generation interpreters consult the current size and narrow the effective sampling range relative to `min...max` before drawing. Reflection, analysis, and tree construction ignore this field — the declared range is authoritative for them.
    case chooseBits(
        min: UInt64,
        max: UInt64,
        tag: TypeTag,
        isRangeExplicit: Bool,
        scaling: ChooseBitsScaling? = nil
    )

    /// Stack-safe sequence generation for creating arrays and collections.
    ///
    /// This operation enables the generation of variable-length collections without recursive bind chains that could cause stack overflow. It's the foundation for `Gen.arrayOf` and similar collection generators.
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
    /// **Stack safety**: Unlike recursive monadic composition, this operation is interpreted iteratively by the interpreter, avoiding deep call stacks for large collections.
    ///
    /// - Parameters:
    ///   - length: Generator that determines the sequence length.
    ///   - gen: Generator applied to each element position.
    case sequence(length: ReflectiveGenerator<UInt64>, gen: ReflectiveGenerator<Any>)

    /// Parallel composition of multiple generators into a tuple result.
    ///
    /// This operation enables clean composition of multiple generators without deeply nested monadic bind chains ("pyramid of doom"). It's essential for building generators that combine several independent random choices.
    ///
    /// **Forward pass**: Generates values from all generators and combines into tuple
    /// **Backward pass**: Decomposes target tuple and reflects each component independently
    /// **Replay pass**: Replays all generators using corresponding choice sub-trees
    ///
    /// **Performance**: ContiguousArray provides better cache locality than Array when iterating through generators during interpretation.
    ///
    /// **Type erasure**: All generators are erased to `ReflectiveGenerator<Any>` because Swift enums cannot store heterogeneous generic types. The interpreter handles type-safe reconstruction of the final tuple.
    ///
    /// - Parameters:
    ///   - generators: Array of generators to compose in parallel.
    ///   - isOpaque: When `true`, the resulting ``ChoiceTree/group(_:isOpaque:)`` is marked opaque so coverage analysis skips its subtree.
    case zip(ContiguousArray<ReflectiveGenerator<Any>>, isOpaque: Bool = false)

    /// Produces a constant value without consuming any randomness.
    ///
    /// This is the simplest operation - it always produces the same predetermined value.
    /// It's the foundation for `Gen.just` and serves as the identity element for generator composition.
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
    /// - Parameter value: The constant value to always produce.
    case just(Any)

    /// Accesses the current size parameter for complexity-scaled generation.
    ///
    /// The size parameter is fundamental to property-based testing - it controls how complex generated values should be. Size typically starts small and grows as tests progress, enabling simple counterexamples to be found before complex ones.
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
    /// **Reflection implications**: During reflection, size represents the complexity of the target value being analyzed, helping guide the search through possible generation paths.
    ///
    /// - Returns: Current size parameter as UInt64.
    case getSize

    /// Temporarily overrides the size parameter for a nested generator scope.
    ///
    /// This operation enables fine-grained control over generation complexity by setting a specific size for part of the generator tree. The size change is scoped - it only affects the nested generator and its descendants.
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
    ///   - newSize: Temporary size parameter for the nested scope.
    ///   - next: Generator to run with the modified size.
    case resize(newSize: UInt64, next: ReflectiveGenerator<Any>)

    /// Identifies generators with validity conditions that can be optimized.
    ///
    /// This operation marks generators that have specific validity requirements or preconditions that make them candidates for optimization through Choice Gradient Sampling (CGS) or rejection sampling. The filter operation enables the framework to automatically detect and improve generators that would otherwise waste computational resources on invalid inputs.
    ///
    /// **Forward pass**: Generates values using the wrapped generator and validates them with the predicate
    /// **Backward pass**: Only reflects on values that satisfy the predicate condition
    /// **Replay pass**: Replays the wrapped generator if the recorded choice satisfied the predicate
    ///
    /// **CGS Optimization**: When a `filter` operation is detected, the Choice Gradient Sampling system can analyze which random choices lead to predicate satisfaction. This enables automatic bias adjustment to increase the proportion of valid outputs without manual generator tuning.
    ///
    /// **Rejection Sampling Fallback**: For generators that aren't suitable for CGS optimization, the filter serves as a signal to use rejection sampling, generating candidates until the predicate is satisfied.
    ///
    /// **Fingerprint**: The fingerprint parameter provides a unique identifier for the specific validity condition, enabling the optimization system to cache learned gradients and apply them across different generator instances with the same logical constraints.
    ///
    /// **Use cases**:
    /// - Balanced binary search trees (structural validity)
    /// - Valid email addresses (format constraints)
    /// - Non-empty collections (size constraints)
    /// - Mathematical invariants (value relationships)
    ///
    /// - Parameters:
    ///   - gen: The base generator to filter.
    ///   - fingerprint: Unique identifier for this filter condition (for optimization caching).
    ///   - filterType: Strategy to use for satisfying the predicate.
    ///   - predicate: Validity condition that generated values must satisfy.
    ///   - tuned: Pre-tuned generator with baked CGS weights, used by generation interpreters. Reduction interpreters ignore this and use `gen` directly.
    ///   - sourceLocation: Source location of the `.filter(...)` call site, for diagnostic warnings.
    case filter(
        gen: ReflectiveGenerator<Any>,
        fingerprint: UInt64,
        filterType: FilterType,
        predicate: (Any) -> Bool,
        tuned: ReflectiveGenerator<Any>?,
        sourceLocation: FilterSourceLocation
    )

    /// Categorizes generated values for statistical analysis and test coverage reporting.
    ///
    /// This operation enables developers to understand the distribution of generated test data by applying labeled predicates to each generated value. The framework automatically collects statistics and reports percentages when testing completes.
    ///
    /// **Forward pass**: Generates values normally while testing against all classifiers
    /// **Backward pass**: Reflects normally (classification doesn't affect reflection)
    /// **Replay pass**: Replays normally (classification is analysis, not generation)
    ///
    /// **Statistical reporting**: When test execution reaches `maxRuns`, the interpreter automatically prints distribution statistics showing what percentage of generated values satisfied each classifier, enabling developers to verify test coverage and identify generator bias.
    ///
    /// **Use cases**:
    /// - Debug generator coverage: "Am I generating edge cases?"
    /// - Verify test quality: "Are tests exercising the scenarios I care about?"
    /// - Tune generator weights: "Should I adjust probabilities?"
    ///
    /// - Parameters:
    ///   - gen: The base generator to classify.
    ///   - fingerprint: Unique identifier for this classification operation.
    ///   - classifiers: Array of (label, predicate) pairs for categorizing values.
    case classify(
        gen: ReflectiveGenerator<Any>,
        fingerprint: UInt64,
        classifiers: [(label: String, predicate: (Any) -> Bool)]
    )

    /// Deduplicates generated values, ensuring each output is unique.
    ///
    /// This operation wraps a generator and tracks previously seen outputs to prevent duplicates. Two deduplication strategies are supported:
    ///
    /// - **Choice-sequence based** (`keyExtractor == nil`): Deduplicates by the flattened ``ChoiceSequence`` of the inner generator's choice tree. Two values are considered duplicates if they were produced by the same random choices, even if the resulting values differ in non-deterministic ways.
    ///
    /// - **Key-based** (`keyExtractor != nil`): Deduplicates by a user-provided key extracted from the generated value. This enables value-based deduplication using key paths or arbitrary transforms.
    ///
    /// **Forward pass**: Generates values and checks against seen set; retries on duplicates
    /// **Backward pass**: Passes through to inner generator (no dedup during reflection)
    /// **Replay pass**: Passes through to inner generator (no dedup during replay)
    ///
    /// - Parameters:
    ///   - gen: The base generator to deduplicate.
    ///   - fingerprint: Unique identifier for this unique site (for per-site tracking).
    ///   - keyExtractor: Optional function to extract a hashable key from generated values.
    ///     When `nil`, deduplication uses the choice sequence instead.
    case unique(
        gen: ReflectiveGenerator<Any>,
        fingerprint: UInt64,
        keyExtractor: ((Any) -> AnyHashable)?
    )

    /// Forward-only transformation of the inner generator's output.
    ///
    /// This operation reifies `map` and `bind` calls as inspectable data, making them visible to interpreters, debuggers, and analysis passes. The transform function is forward-only — it cannot be inverted during reflection.
    ///
    /// **Forward pass**: Interpret `inner`, apply the transform function to the result
    /// **Backward pass**: Fails with a diagnostic error — the transform is not invertible
    /// **Replay pass**: Replay `inner`, apply the transform function to the result
    ///
    /// **Structural dual of `contramap`**: `contramap` transforms backward/input; `transform` transforms forward/output.
    ///
    /// For bidirectional transforms, use `mapped(forward:backward:)` which pairs a `contramap` with an invisible `_map` — no `.transform` operation is created.
    ///
    /// - Parameters:
    ///   - kind: Whether this is a `map` (pure function) or `bind` (dependent generator).
    ///   - inner: The generator whose output is being transformed.
    case transform(kind: TransformKind, inner: ReflectiveGenerator<Any>)
}

/// Describes the kind of forward-only transformation applied by a `.transform` operation.
public enum TransformKind {
    /// A pure function applied to the inner generator's output.
    ///
    /// - Parameters:
    ///   - forward: The transform function (type-erased). Throws if the transformation fails.
    ///   - inputType: The metatype of the input, captured at the call site.
    ///   - outputType: The metatype of the output, captured at the call site.
    case map(forward: (Any) throws -> Any, inputType: Any.Type, outputType: Any.Type)

    /// A dependent generator derived from the inner generator's output.
    ///
    /// - Parameters:
    ///   - fingerprint: Stable hash of the bind's source location (`#fileID + #line + #column`), used to key the classification cache on ``ChoiceGraph``. Distinct call sites get distinct fingerprints; recursive instantiations of the same call site share one.
    ///   - forward: A function that takes the inner generator's output and returns a new generator.
    ///   - backward: Optional extraction function `(B) -> A` for reflection. When non-nil, enables
    ///     the reflector to decompose the output back through the bind. `nil` = forward-only.
    ///   - inputType: The metatype of the input, captured at the call site.
    ///   - outputType: The metatype of the output, captured at the call site.
    case bind(
        fingerprint: UInt64,
        forward: (Any) throws -> ReflectiveGenerator<Any>,
        backward: ((Any) throws -> Any)?,
        inputType: Any.Type,
        outputType: Any.Type
    )

    /// Generates independent copies of the inner value and applies a different transform to each.
    ///
    /// The interpreter saves PRNG state before generating the inner value, then restores and re-generates for each transform to produce independent copies. The result is an ``Array`` of ``Any`` where index zero is the untransformed original (for reflection backward) and indices one through N are the transformed copies.
    ///
    /// - Parameters:
    ///   - transforms: Type-erased transform functions, one per copy.
    ///   - inputType: The metatype of the inner generator's output, for diagnostics.
    case metamorphic(
        transforms: [(Any) throws -> Any],
        inputType: Any.Type
    )
}

extension ReflectiveOperation {

    // MARK: - Inner Generator Mapping

    /// Applies a transform to this operation's single inner sub-generator, if it has one.
    ///
    /// Returns the rebuilt operation for wrapper operations that contain exactly one sub-generator (`contramap`, `prune`, `resize`, `filter`, `classify`, `unique`, `transform`).
    /// Returns `nil` for operations with zero or multiple sub-generators (`chooseBits`, `just`, `getSize`, `pick`, `zip`, `sequence`, `metamorphic`).
    package func mapInnerGenerator(
        _ transform: (ReflectiveGenerator<Any>) throws -> ReflectiveGenerator<Any>
    ) rethrows -> ReflectiveOperation? {
        switch self {
        case let .contramap(contramapTransform, next):
            return .contramap(transform: contramapTransform, next: try transform(next))

        case let .prune(next):
            return .prune(next: try transform(next))

        case let .resize(newSize, next):
            return .resize(newSize: newSize, next: try transform(next))

        case let .filter(gen, fingerprint, filterType, predicate, tuned, sourceLocation):
            return .filter(
                gen: try transform(gen),
                fingerprint: fingerprint,
                filterType: filterType,
                predicate: predicate,
                tuned: try tuned.map(transform),
                sourceLocation: sourceLocation
            )

        case let .classify(gen, fingerprint, classifiers):
            return .classify(
                gen: try transform(gen),
                fingerprint: fingerprint,
                classifiers: classifiers
            )

        case let .unique(gen, fingerprint, keyExtractor):
            return .unique(
                gen: try transform(gen),
                fingerprint: fingerprint,
                keyExtractor: keyExtractor
            )

        case let .transform(kind, inner):
            return .transform(kind: kind, inner: try transform(inner))

        case .chooseBits, .just, .getSize, .pick, .zip, .sequence:
            return nil
        }
    }
}
