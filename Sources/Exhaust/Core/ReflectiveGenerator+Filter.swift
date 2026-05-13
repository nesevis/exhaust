//
//  ReflectiveGenerator+Filter.swift
//  Exhaust
//
//  Created by Chris Kolbu on 13/5/2026.
//

public extension ReflectiveGenerator {
    /// Creates a filtered generator that only produces values satisfying a predicate.
    ///
    /// The filter combinator supports several strategies for satisfying the predicate, selectable via the `type` parameter:
    ///
    /// - ``FilterType/rejectionSampling``: Generates values and discards those that fail the predicate. Best when most values already satisfy the predicate (for example, filtering positive integers from a 0...100 range). Becomes slow or exhausts the retry budget when valid values are rare.
    /// - ``FilterType/probeSampling``: Analyzes each branching point independently to bias toward valid outputs. Faster startup than ``FilterType/choiceGradientSampling`` and effective when validity depends on individual choices, but produces less diverse output for generators where validity is correlated across choices (for example, balanced tree generators).
    /// - ``FilterType/choiceGradientSampling``: Runs a warmup pass to learn which combinations of choices lead to valid outputs, then biases generation accordingly. Produces the best balance of validity rate and output diversity for complex or recursive generators. The warmup adds a brief startup cost that is not worthwhile when the predicate already accepts most values.
    /// - ``FilterType/auto`` (default): Uses ``FilterType/choiceGradientSampling``. Override with ``FilterType/rejectionSampling`` when the predicate already accepts most values and the warmup cost is not worthwhile.
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
    func filter(
        _ type: FilterType = .auto,
        _ predicate: @Sendable @escaping (Output) -> Bool,
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) -> ReflectiveGenerator<Output> {
        Gen.filter(
            gen,
            type: type,
            predicate: predicate,
            sourceLocation: FilterSourceLocation(
                fileID: fileID,
                filePath: filePath,
                line: line,
                column: column
            )
        ).wrapped
    }
}
