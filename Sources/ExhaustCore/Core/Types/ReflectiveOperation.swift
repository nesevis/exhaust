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

// MARK: - Why One Enum
//
// Thirteen cases in one enum rather than separate "structural" and "modifier" enums.
//
// 1. Swift exhaustive switch checking enforces that every interpreter handles every case. Splitting into two enums loses this guarantee at the composition boundary — a new interpreter could silently ignore all modifier cases.
//
// 2. The "transparent" cases (classify, unique, filter, resize) are not uniformly transparent. Tuning has dedicated handlers for all four. Generation interprets filter with CGS-aware logic. Only replay treats classify/unique as pure pass-throughs. A two-enum split would suggest a uniformity that does not exist.
//
// 3. mapInnerGenerator() already factors the structural recursion pattern for cases that wrap a single inner generator. Adaptation uses it at three call sites. A second enum would not reduce code beyond what this method already eliminates.

// swiftlint:disable:next orphaned_doc_comment
/// The primitive operations that enable bidirectional property-based testing.
///
/// Each case is interpreted by multiple passes (generation, reflection, replay, adaptation). The interpretation table in the MARK section below lists which source file handles each case in each pass. Per-case doc comments explain design rationale and invariants, not interpreter behavior.
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
/// - SeeAlso: ``Generator``, ``Gen``, ``Interpreters``
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

@usableFromInline
package enum ReflectiveOperation {
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
        package let generator: AnyGenerator

        /// Creates a pick tuple with the given fingerprint, identifier, weight, and generator.
        public init(
            fingerprint: UInt64,
            id: UInt64,
            weight: UInt64,
            generator: AnyGenerator
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
    case contramap(transform: (Any) throws -> Any?, next: AnyGenerator)

    /// Selects one of several discrete generation strategies by weighted random draw.
    ///
    /// Pick is a primitive because weighted discrete choice cannot be composed from ``chooseBits``: branches carry distinct sub-generators with different recursive structures, not just different bit patterns in a contiguous range. The ChoiceGraph builds a separate subtree per branch, and the reducer can swap, reorder, or eliminate branches independently — none of which is possible when the choice is encoded as a numeric range.
    ///
    /// **Invariants:** Every ``PickTuple/generator`` is type-erased to `AnyGenerator` and must produce a value whose type matches the continuation attached to this operation. `branchCount` must equal `choices.count`; the two are stored separately because `branchCount` is needed at sites that do not inspect individual branches (for example, ChoiceTree construction).
    ///
    /// - Parameters:
    ///   - choices: Array of weighted generator options with replay labels.
    ///   - branchCount: The number of branches at this pick site. Branch identifiers are `0 ..< branchCount`.
    case pick(choices: ContiguousArray<PickTuple>, branchCount: UInt64)

    /// Eliminates a reflection branch when the preceding ``contramap`` returns `nil`.
    ///
    /// **Why separate from contramap:** Contramap transforms the input; prune decides whether to continue. Merging them into a single operation would force every contramap to handle the nil case even when failure is impossible, and would hide the branch-elimination decision from interpreters that need to count or log pruned paths. The separation lets the reflection interpreter distinguish "transform succeeded but downstream failed" from "transform itself rejected this branch."
    ///
    /// - Parameter next: Generator to apply if the input is valid (non-nil).
    case prune(next: AnyGenerator)

    /// Generates a random `UInt64` bit pattern within `min...max`, interpreted as a typed value via ``TypeTag``.
    ///
    /// Bit-pattern-space generation is the unified primitive for all numeric, boolean, and character types because it reduces every bounded domain to a single contiguous `UInt64` range. This lets interpreters, reducers, and coverage analysis share one code path regardless of the output type. The ``TypeTag`` carries enough information to convert between the bit pattern and the domain value in both directions, which is what makes reflection and boundary analysis work without per-type interpreter logic.
    ///
    /// `isRangeExplicit` distinguishes user-declared ranges (for example, `Gen.int(in: 0...100)`) from ranges synthesized by size scaling. The reducer must respect explicit ranges as hard bounds — narrowing them would change the generator's contract — but may freely narrow implicit ranges because they are artifacts of the current size parameter.
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

    /// Generates a variable-length array by first choosing a length, then generating that many elements.
    ///
    /// Sequence is a primitive because variable-length output requires a data-dependent number of sub-generators — one length choice followed by N element choices — which cannot be expressed as a fixed ``zip``. Encoding this as a chain of binds would work semantically but causes O(N) stack depth; the sequence operation is interpreted iteratively, keeping stack depth constant regardless of collection size.
    ///
    /// **Invariant:** The `length` generator must produce a `UInt64`. The element generator is instantiated once and reused for every position; per-index variation must be encoded inside the element generator itself, not by varying the generator across positions.
    ///
    /// - Parameters:
    ///   - length: Generator that determines the sequence length.
    ///   - gen: Generator applied to each element position.
    case sequence(length: Generator<UInt64>, gen: AnyGenerator)

    /// Composes a fixed number of independent generators into a single tuple result.
    ///
    /// Zip is a primitive because fixed-arity parallel composition is structurally distinct from ``sequence``'s variable-length output. The ChoiceTree knows the child count at construction time, so coverage analysis can enumerate parameter combinations without generating a length first. The reducer treats each child as an independent scope, which is not possible when variable-length output forces all elements through a shared element generator.
    ///
    /// **Invariant:** All generators are type-erased to `AnyGenerator`. The continuation attached to this operation receives an `[Any]` whose count and element types match the generators array. The interpreter does not validate element types — the combinator that constructed the zip guarantees the correspondence.
    ///
    /// - Parameters:
    ///   - generators: Array of generators to compose in parallel.
    ///   - isOpaque: When `true`, the resulting ``ChoiceTree/group(_:isOpaque:)`` is marked opaque so coverage analysis skips its subtree.
    case zip(ContiguousArray<AnyGenerator>, isOpaque: Bool = false)

    /// Embeds a constant value into the generator tree. Produces a `.just` marker in the ``ChoiceSequence`` but carries no randomness — the value is fixed for the lifetime of the generator and the reducer cannot minimize through it.
    ///
    /// Exists as a primitive rather than using ``FreerMonad/pure`` because the reflector must distinguish a deliberate constant from a continuation terminal. Both are `.pure` in the Freer Monad; `.just` is the marker that tells interpreters which one they are looking at.
    ///
    /// Common uses: base cases of ``Gen/recursive(base:maxDepth:extend:)`` generators, default branches of pick operations, and placeholder generators in opaque zips.
    ///
    /// - Parameter value: The constant value to always produce.
    case just(Any)

    /// Reads the interpreter's current size parameter, which controls generation complexity.
    ///
    /// Size gates how large or deep generated values grow: array lengths, tree depths, and string lengths are typically derived from it. Generators built with ``chooseBits`` and `ChooseBitsScaling` narrow their effective range based on size automatically, but generators that need the raw size value (for example, to compute a recursive depth budget) read it through this operation.
    ///
    /// During reflection, size maps to the integer range, so the backward pass always succeeds. This means getSize-dependent generators remain reflectable, but the reflected size may not match the original — it represents "a size that could have produced this value," not the exact size used during generation.
    case getSize

    /// Overrides the size parameter for a nested generator scope.
    ///
    /// Used when an inner generator needs a different complexity budget than its parent — for example, capping recursive depth or forcing small collections inside a larger structure. The override is lexically scoped: any ``getSize`` or ``chooseBits`` with scaling inside `next` sees `newSize`, but the enclosing generator's size is restored after `next` completes.
    ///
    /// - Parameters:
    ///   - newSize: Temporary size parameter for the nested scope.
    ///   - next: Generator to run with the modified size.
    case resize(newSize: UInt64, next: AnyGenerator)

    /// Marks a generator with a validity predicate that the framework can optimize via Choice Gradient Sampling (CGS).
    ///
    /// Filter is reified as a primitive rather than implemented as plain rejection sampling so that the CGS pipeline can inspect the predicate boundary, subdivide the inner generator's choice space, and learn per-choice biases that steer generation toward valid outputs. Without reification, the framework would see only an opaque closure and fall back to unguided rejection sampling.
    ///
    /// The `fingerprint` keys the CGS weight cache: distinct call sites get distinct fingerprints, so learned biases are not shared across unrelated filter conditions. The `tuned` field holds the pre-baked generator after CGS tuning completes; generation interpreters use it in place of `gen` to avoid re-tuning on every invocation. Reduction interpreters always use `gen` directly because they operate on the original choice structure, not the tuned one.
    ///
    /// - Parameters:
    ///   - gen: The base generator to filter.
    ///   - fingerprint: Unique identifier for this filter condition (for optimization caching).
    ///   - filterType: Strategy to use for satisfying the predicate.
    ///   - predicate: Validity condition that generated values must satisfy.
    ///   - tuned: Pre-tuned generator with baked CGS weights, used by generation interpreters. Reduction interpreters ignore this and use `gen` directly.
    ///   - sourceLocation: Source location of the `.filter(...)` call site, for diagnostic warnings.
    case filter(
        gen: AnyGenerator,
        fingerprint: UInt64,
        filterType: FilterType,
        predicate: (Any) -> Bool,
        tuned: AnyGenerator?,
        sourceLocation: FilterSourceLocation
    )

    /// Attaches observational labels to generated values without affecting generation, reflection, or replay.
    ///
    /// Classification is purely observational: it does not alter the choice sequence, steer sampling, or prune reflection paths. It exists so that ``ClassificationExploreRunner`` can track which `#explore` directions each generated value satisfies, and so that the test runner can report distribution statistics at the end of a run. Because it is transparent to all interpreter passes, adding or removing a classify wrapper never changes the values a generator produces.
    ///
    /// - Parameters:
    ///   - gen: The base generator to classify.
    ///   - fingerprint: Unique identifier for this classification operation.
    ///   - classifiers: Array of (label, predicate) pairs for categorizing values.
    case classify(
        gen: AnyGenerator,
        fingerprint: UInt64,
        classifiers: [(label: String, predicate: (Any) -> Bool)]
    )

    /// Deduplicates generated values, ensuring each output is unique within a single test iteration.
    ///
    /// Two deduplication strategies are supported:
    ///
    /// - **Choice-sequence based** (`keyExtractor == nil`): Deduplicates by the flattened ``ChoiceSequence`` of the inner generator's choice tree. Two values are considered duplicates if they were produced by the same random choices, even if the resulting values differ in non-deterministic ways.
    ///
    /// - **Key-based** (`keyExtractor != nil`): Deduplicates by a user-provided key extracted from the generated value. This enables value-based deduplication using key paths or arbitrary transforms.
    ///
    /// Unique is transparent to reflection and replay — deduplication is a generation-time concern only. The seen set is keyed by `fingerprint` so that multiple unique sites in the same generator tree maintain independent tracking.
    ///
    /// - Parameters:
    ///   - gen: The base generator to deduplicate.
    ///   - fingerprint: Unique identifier for this unique site (for per-site tracking).
    ///   - keyExtractor: Optional function to extract a hashable key from generated values. When `nil`, deduplication uses the choice sequence instead.
    case unique(
        gen: AnyGenerator,
        fingerprint: UInt64,
        keyExtractor: ((Any) -> AnyHashable)?
    )

    /// Reifies a forward-only `map` or `bind` as inspectable data visible to interpreters and analysis passes.
    ///
    /// Structural dual of ``contramap``: contramap transforms the backward (input) side; transform transforms the forward (output) side. Because the transform function is not invertible, reflection through a `.transform` fails with a diagnostic error. For bidirectional transforms, use `mapped(forward:backward:)`, which pairs a contramap with an invisible `map` — no `.transform` operation is created.
    ///
    /// Forward-only transforms do not degrade reduction. The reducer operates on choice sequences, not on reflected values, so a non-invertible output transform has no effect on shrinking quality.
    ///
    /// - Parameters:
    ///   - kind: Whether this is a `map` (pure function) or `bind` (dependent generator).
    ///   - inner: The generator whose output is being transformed.
    case transform(kind: TransformKind, inner: AnyGenerator)
}

/// Describes the kind of forward-only transformation applied by a `.transform` operation.
@usableFromInline
package enum TransformKind {
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
        forward: (Any) throws -> AnyGenerator,
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

package extension ReflectiveOperation {
    // MARK: - Inner Generator Mapping

    /// Applies a transform to this operation's single inner sub-generator, if it has one.
    ///
    /// Returns the rebuilt operation for wrapper operations that contain exactly one sub-generator (`contramap`, `prune`, `resize`, `filter`, `classify`, `unique`, `transform`).
    /// Returns `nil` for operations with zero or multiple sub-generators (`chooseBits`, `just`, `getSize`, `pick`, `zip`, `sequence`, `metamorphic`).
    func mapInnerGenerator(
        _ transform: (AnyGenerator) throws -> AnyGenerator
    ) rethrows -> ReflectiveOperation? {
        switch self {
        case let .contramap(contramapTransform, next):
            return try .contramap(transform: contramapTransform, next: transform(next))

        case let .prune(next):
            return try .prune(next: transform(next))

        case let .resize(newSize, next):
            return try .resize(newSize: newSize, next: transform(next))

        case let .filter(gen, fingerprint, filterType, predicate, tuned, sourceLocation):
            return try .filter(
                gen: transform(gen),
                fingerprint: fingerprint,
                filterType: filterType,
                predicate: predicate,
                tuned: tuned.map(transform),
                sourceLocation: sourceLocation
            )

        case let .classify(gen, fingerprint, classifiers):
            return try .classify(
                gen: transform(gen),
                fingerprint: fingerprint,
                classifiers: classifiers
            )

        case let .unique(gen, fingerprint, keyExtractor):
            return try .unique(
                gen: transform(gen),
                fingerprint: fingerprint,
                keyExtractor: keyExtractor
            )

        case let .transform(kind, inner):
            return try .transform(kind: kind, inner: transform(inner))

        case .chooseBits, .just, .getSize, .pick, .zip, .sequence:
            return nil
        }
    }
}
