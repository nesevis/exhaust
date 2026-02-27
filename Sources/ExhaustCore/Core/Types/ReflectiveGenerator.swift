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
}
