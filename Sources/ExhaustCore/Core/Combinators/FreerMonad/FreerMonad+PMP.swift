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
}
