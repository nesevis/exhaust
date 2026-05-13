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
    func filter(
        _ type: FilterType = .auto,
        _ predicate: @Sendable @escaping (Output) -> Bool,
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column
    ) -> ReflectiveGenerator<Output> {
        ReflectiveGenerator {
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
            )
        }
    }
}
