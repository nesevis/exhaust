/// A bidirectional generator that can produce values, reflect on them, and replay recorded choices.
///
/// Operates in three modes, each driven by a different interpreter over the same ``FreerMonad`` structure:
///
/// ## 1. Generation (Forward Pass)
/// Produces random values using entropy, just like traditional generators.
///
/// ## 2. Reflection (Backward Pass)
/// Analyzes any value to discover which random choices could have produced it. This enables reduction of values that were not produced by the PRNG — for example, values from crash reports or external test corpora.
///
/// ## 3. Replay (Deterministic Forward)
/// Recreates exact values from recorded choice paths.
///
/// Without reflection, a reducer can only simplify values it generated itself and still holds traces for. With reflection, the reducer can accept any value of the output type and decompose it into a choice sequence, making reduction, mutation, and example-based generation work on values from any source.
///
/// Generator is a type alias for `FreerMonad<ReflectiveOperation, Output>`, separating the description of generation from its interpretation. The bidirectional generator design is based on Harrison Goldstein's dissertation, "Property-Based Testing for the People" (UPenn, 2024).
///
/// **Construction**: Use ``Gen`` combinators, never construct directly.
///
/// - SeeAlso: ``Gen`` for generator construction, ``Interpreters`` for execution
@usableFromInline
package typealias Generator<Output> = FreerMonad<ReflectiveOperation, Output>
@usableFromInline
package typealias AnyGenerator = FreerMonad<ReflectiveOperation, Any>

package extension Generator where Operation == ReflectiveOperation {
    /// Reifies a monadic bind as a visible `.transform(.bind(...))` operation in the generator tree.
    ///
    /// Unlike the invisible ``FreerMonad/bind(_:)`` used by internal framework code, this method creates an inspectable node that the reflection interpreter, reducer, and coverage analysis can see and traverse. The backward function (when provided via ``_bound(forward:backward:fileID:line:column:)``) enables reflection to decompose the bound value back into the inner generator's output.
    ///
    /// This method was renamed from `_bind` to avoid an overload-resolution conflict with ``FreerMonad/bind(_:)``. When both methods had identical externally-visible signatures (one parameter), Swift correctly picked this constrained-extension version over the generic one. Adding defaulted parameters for `#fileID`/`#line`/`#column` changed the resolution preference, silently routing call sites to the unconstrained ``FreerMonad/bind(_:)`` (which chains continuations natively without reifying as `.transform(.bind(...))`). Renaming to `bindReified` eliminates the ambiguity entirely; the source-location defaults can stay because the rename guarantees there is no other `bindReified` to compete with.
    ///
    /// - Parameter transform: A function that takes the current value and produces a new computation.
    /// - Returns: A new computation representing the sequenced effects.
    func bindReified<NewValue>(
        _ transform: @escaping (Value) throws -> FreerMonad<Operation, NewValue>,
        fileID: StaticString = #fileID,
        line: UInt = #line,
        column: UInt = #column
    ) rethrows -> FreerMonad<Operation, NewValue> {
        let fingerprint = Gen.sourceFingerprint(fileID: fileID, line: line, column: column)
        return Gen.liftF(.transform(
            kind: .bind(
                fingerprint: fingerprint,
                forward: { try transform($0 as! Value).erase() },
                backward: nil,
                inputType: Value.self,
                outputType: NewValue.self
            ),
            inner: erase()
        ))
    }

    /// Chains this generator with a dependent generator, with a backward extraction function for reflection.
    ///
    /// This is the bind-level analogue of ``mapped(forward:backward:)``. The `backward` function extracts the inner generator's input from the final output, enabling reflection (and therefore reduction) through the bind.
    ///
    /// - **Forward**: Takes the inner value `A` and returns a dependent generator over `B`
    /// - **Backward**: Extracts `A` from a `B` — the `comap` annotation at bind sites (Xia et al. ESOP 2019)
    ///
    /// ```swift
    /// let sized = #gen(.int(in: 1...10))._bound(
    ///     forward: { n in .string(length: n) },
    ///     backward: { str in str.count }
    /// )
    /// ```
    ///
    /// - Parameters:
    ///   - forward: Function that takes the generated value and returns a new generator.
    ///   - backward: Function that extracts the inner value from the final output.
    /// - Returns: A generator that sequences the two computations with bidirectional support.
    func _bound<NewValue>(
        forward: @escaping (Value) throws -> Generator<NewValue>,
        backward: @escaping (NewValue) throws -> Value,
        fileID: StaticString = #fileID,
        line: UInt = #line,
        column: UInt = #column
    ) rethrows -> Generator<NewValue> {
        let fingerprint = Gen.sourceFingerprint(fileID: fileID, line: line, column: column)
        return Gen.liftF(.transform(
            kind: .bind(
                fingerprint: fingerprint,
                forward: { try forward($0 as! Value).erase() },
                backward: { try backward($0 as! NewValue) as Any },
                inputType: Value.self,
                outputType: NewValue.self
            ),
            inner: erase()
        ))
    }

    /// Returns whether this generator is a terminal ``FreerMonad/pure`` value with no remaining operations. Used as the recursion base in analysis passes (for example ``ChoiceTreeAnalysis``) and by combinators that need to detect constant generators.
    var isPure: Bool {
        if case .pure = self { return true }
        return false
    }

    /// Exposes the explicit min/max constraint of a ``chooseBits`` leaf without interpreting the full generator. Used by ``FiniteDomainProfile`` and coverage analysis to collect parameter ranges for covering-array construction. Returns nil for pure values, non-``chooseBits`` operations, or ranges derived from size scaling (which are not stable across runs).
    var associatedRange: ClosedRange<UInt64>? {
        switch self {
            case .pure:
                return nil
            case let .impure(op, _):
                guard case let .chooseBits(min, max, _, isRangeExplicit, _) = op,
                      isRangeExplicit
                else {
                    return nil
                }
                return min ... max
        }
    }
}

// MARK: - ReflectiveGenerator (Public Struct)

/// Produces arbitrary values for property-based testing.
///
/// Construct generators with static factory methods (`.int()`, `.string()`, `.bool()`, and so on) or the `#gen` macro, then combine them with `.array()`, `.filter()`, `.map()`, and pass the result to `#exhaust`.
///
/// ```swift
/// let gen = ReflectiveGenerator.int(in: 0...100)
///     .array(length: 1...10)
///     .filter { $0.contains(where: { $0 > 50 }) }
///
/// #exhaust(gen) { array in
///     array.sorted() == array // finds unsorted arrays
/// }
/// ```
///
/// When a property fails, Exhaust automatically reduces the counterexample to a minimal failing case. Generators that support bidirectional transforms — ``mapped(forward:backward:)`` and ``bound(forward:backward:)`` — also enable ``#examine`` to decompose a concrete value back into its generator inputs.
///
/// - Note: `@unchecked Sendable` is safe because the underlying indirect enum stores only `@Sendable` closures and `Sendable` value types. The compiler cannot verify sendability through the indirection automatically.
public struct ReflectiveGenerator<Output>: @unchecked Sendable {
    package let gen: Generator<Output>

    /// Whether this generator was synthesized from a `Decodable` type via ``GeneratorSynthesizer``.
    ///
    /// Generators synthesized from JSON example data may contain `.just` nodes for fields where the ``GeneratorSynthesizer`` could not build a full generator (for example, non-`CaseIterable` enums). These fields are pinned to the constant value from the example JSON. Diagnostic tools can check this flag to distinguish synthesized generators from hand-written ones.
    public let isSynthesized: Bool

    /// Wraps an already-constructed generator.
    package init(_ gen: Generator<Output>, isSynthesized: Bool = false) {
        self.gen = gen
        self.isSynthesized = isSynthesized
    }

    /// Chains this generator with a dependent generator whose structure depends on the produced value.
    ///
    /// Use `.bind` when the next generator genuinely depends on the value from this one — for example, generating an array whose length is determined by a previously generated integer. When generators are independent, prefer `#gen(a, b) { ... }` — they compose without introducing a dependency edge in the choice graph.
    ///
    /// - Parameter transform: A function that takes the generated value and returns a new generator.
    /// - Returns: A generator that sequences the two computations.
    public func bind<NewOutput>(
        _ transform: @Sendable @escaping (Output) throws -> ReflectiveGenerator<NewOutput>,
        fileID: StaticString = #fileID,
        line: UInt = #line,
        column: UInt = #column
    ) rethrows -> ReflectiveGenerator<NewOutput> {
        let fingerprint = Gen.sourceFingerprint(fileID: fileID, line: line, column: column)
        return Gen.liftF(.transform(
            kind: .bind(
                fingerprint: fingerprint,
                forward: { try transform($0 as! Output).gen.erase() },
                backward: nil,
                inputType: Output.self,
                outputType: NewOutput.self
            ),
            inner: gen.erase()
        )).wrapped
    }

    /// Applies a forward-only transform to the generated value.
    ///
    /// Reduction is unaffected: the reducer operates on the choice sequence, not the transformed output. Reflection is not supported through this transform — ``#examine`` will report a forward-only warning. For reflection support, use ``mapped(forward:backward:)`` or ``#gen`` with a trailing closure.
    ///
    /// ```swift
    /// let lengths = #gen(.asciiString()).map { $0.count }
    /// ```
    ///
    /// - Parameter transform: A function to apply to each generated value.
    /// - Returns: A generator producing the transformed values.
    public func map<NewOutput>(
        _ transform: @Sendable @escaping (Output) throws -> NewOutput
    ) rethrows -> ReflectiveGenerator<NewOutput> {
        Gen.liftF(.transform(
            kind: .map(
                forward: { try transform($0 as! Output) },
                inputType: Output.self,
                outputType: NewOutput.self
            ),
            inner: gen.erase()
        )).wrapped
    }
}

// MARK: - Generator → ReflectiveGenerator

package extension FreerMonad where Operation == ReflectiveOperation {
    /// Wraps this generator in a ``ReflectiveGenerator``.
    var wrapped: ReflectiveGenerator<Value> {
        ReflectiveGenerator(self)
    }
}

// MARK: - CustomDebugStringConvertible

extension ReflectiveGenerator: CustomDebugStringConvertible {
    public var debugDescription: String {
        let typeName = "\(Output.self)"
        let synthesized = isSynthesized ? " (synthesized)" : ""
        return "ReflectiveGenerator<\(typeName)>(\(synthesized)\n"
            + gen.treeDescription(prefix: "", isLast: true)
    }
}
