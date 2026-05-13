/// A bidirectional generator that can both produce values and reflect on them.
///
/// ReflectiveGenerator is the foundation of advanced property-based testing, enabling generators that work in **three distinct modes**:
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
/// - **Reduction without traces**: Reduce any value, even from crash reports or external sources
/// - **Mutation testing**: Modify values while preserving validity constraints
/// - **Example-based generation**: Generate similar values to provided examples
/// - **Validation**: Check if values could have been produced by a generator
///
/// ## Implementation
///
/// ReflectiveGenerator is a type alias for `FreerMonad<ReflectiveOperation, Output>`, separating the description of generation from its interpretation. This enables the same generator structure to be used for all three modes through different interpreters.
///
/// The bidirectional generator design is based on Harrison Goldstein's dissertation, "Property-Based Testing for the People" (UPenn, 2024).
///
/// **Construction**: Use ``Gen`` combinators, never construct directly.
///
/// - SeeAlso: ``Gen`` for generator construction, ``Interpreters`` for execution
package typealias ReflectiveGenerator<Output> = FreerMonad<ReflectiveOperation, Output>

package typealias Generator<Output> = FreerMonad<ReflectiveOperation, Output>
package typealias AnyGenerator = FreerMonad<ReflectiveOperation, Any>

package extension ReflectiveGenerator where Operation == ReflectiveOperation {
    /// Reifies a monadic bind as a visible `.transform(.bind(...))` operation in the generator tree.
    ///
    /// Unlike the invisible ``FreerMonad/_bind(_:)`` used by internal framework code, this method creates an inspectable node that the reflection interpreter, reducer, and coverage analysis can see and traverse. The backward function (when provided via ``_bound(forward:backward:fileID:line:column:)``) enables reflection to decompose the bound value back into the inner generator's output.
    ///
    /// This method was renamed from `_bind` to avoid an overload-resolution conflict with ``FreerMonad/_bind(_:)``. When both methods had identical externally-visible signatures (one parameter), Swift correctly picked this constrained-extension version over the generic one. Adding defaulted parameters for `#fileID`/`#line`/`#column` changed the resolution preference, silently routing call sites to the unconstrained ``FreerMonad/_bind(_:)`` (which chains continuations natively without reifying as `.transform(.bind(...))`). Renaming to `_bindReified` eliminates the ambiguity entirely; the source-location defaults can stay because the rename guarantees there is no other `_bindReified` to compete with.
    ///
    /// - Parameter transform: A function that takes the current value and produces a new computation.
    /// - Returns: A new computation representing the sequenced effects.
    func _bindReified<NewValue>(
        _ transform: @escaping (Value) throws -> FreerMonad<Operation, NewValue>,
        fileID: String = #fileID,
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
        forward: @escaping (Value) throws -> ReflectiveGenerator<NewValue>,
        backward: @escaping (NewValue) throws -> Value,
        fileID: String = #fileID,
        line: UInt = #line,
        column: UInt = #column
    ) rethrows -> ReflectiveGenerator<NewValue> {
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
