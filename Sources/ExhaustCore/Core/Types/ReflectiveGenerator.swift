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
public typealias ReflectiveGenerator<Output> = FreerMonad<ReflectiveOperation, Output>

package extension ReflectiveGenerator where Operation == ReflectiveOperation {
    /// Monadic bind operation that sequences computations with effects.
    ///
    /// This is the fundamental operation for chaining effectful computations. It allows you to use the result of one computation to determine the next computation, properly handling both pure values and suspended operations.
    ///
    /// **For pure values:** Immediately applies the transform to get the next computation
    /// **For impure values:** Extends the continuation chain to apply the transform later
    ///
    /// This operation is associative and follows the monad laws, enabling safe composition of complex effectful programs from simpler building blocks.
    ///
    /// - Parameter transform: A function that takes the current value and produces a new computation.
    /// - Returns: A new computation representing the sequenced effects.
    /// - Throws: Rethrows any errors from the transform function
    func _bind<NewValue>(_ transform: @escaping (Value) throws -> FreerMonad<Operation, NewValue>) rethrows -> FreerMonad<Operation, NewValue> {
        Gen.liftF(.transform(
            kind: .bind(
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
        backward: @escaping (NewValue) throws -> Value
    ) rethrows -> ReflectiveGenerator<NewValue> {
        Gen.liftF(.transform(
            kind: .bind(
                forward: { try forward($0 as! Value).erase() },
                backward: { try backward($0 as! NewValue) as Any },
                inputType: Value.self,
                outputType: NewValue.self
            ),
            inner: erase()
        ))
    }

    /// Returns `true` when this generator is a `.pure` value with no pending effects.
    var isPure: Bool {
        if case .pure = self { return true }
        return false
    }

    /// The bit pattern range associated with this generator's immediate choice operation.
    ///
    /// For generators wrapping a `chooseBits` operation, returns the min/max range that constrains the random values. Returns `nil` for pure values or non-choice operations.
    ///
    /// This property is used internally for optimization and analysis of generator constraints.
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
