//
//  Gen+Classify.swift
//  Exhaust
//
//  Created by Chris Kolbu on 14/8/2025.
//

package extension Gen {
    /// Creates a generator that categorizes generated values for statistical analysis.
    ///
    /// Wraps the provided generator with classification predicates that track how frequently different types of test data are generated. When test execution completes, statistics are automatically reported to help developers understand test coverage and generator bias.
    ///
    /// **Usage**: Apply labeled predicates to understand what kinds of values your generator produces:
    /// ```swift
    /// let classifiedInts = Gen.classify(
    ///     Gen.choose(in: 0...100),
    ///     ("small", { $0 < 10 }),
    ///     ("even", { $0 % 2 == 0 }),
    ///     ("large", { $0 > 90 })
    /// )
    /// ```
    ///
    /// **Reporting**: Statistics are printed when the generator reaches `maxRuns`, showing counts and percentages for each classifier. Values can satisfy multiple classifiers simultaneously for comprehensive coverage analysis.
    ///
    /// - Parameters:
    ///   - generator: The base generator to wrap with classification.
    ///   - classifiers: Variadic (label, predicate) pairs for categorizing generated values.
    /// - Returns: A generator that produces the same values while collecting statistics.
    static func classify<Output>(
        _ generator: ReflectiveGenerator<Output>,
        _ classifiers: (String, (Output) -> Bool)...
    ) -> ReflectiveGenerator<Output> {
        .impure(operation:
            .classify(
                gen: generator.erase(),
                fingerprint: 0,
                classifiers: classifiers.map { pair in (pair.0, { pair.1($0 as! Output) }) }
            )) { .pure($0 as! Output) }
    }
}
