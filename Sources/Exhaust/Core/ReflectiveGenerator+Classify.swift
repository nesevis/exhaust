//
//  ReflectiveGenerator+Classify.swift
//  Exhaust
//
//  Created by Chris Kolbu on 13/5/2026.
//

public extension ReflectiveGenerator {
    /// Categorizes generated values for statistical analysis.
    ///
    /// Wraps this generator with classification predicates that track how frequently different types of test data are generated.
    ///
    /// ```swift
    /// let classified = #gen(.int(in: 0...100)).classify(
    ///     ("small", { $0 < 10 }),
    ///     ("large", { $0 > 90 })
    /// )
    /// ```
    func classify(
        _ classifiers: (String, @Sendable (Output) -> Bool)...,
        fileID: StaticString = #fileID,
        line: UInt = #line,
        column: UInt = #column
    ) -> ReflectiveGenerator<Output> {
        let fingerprint = Gen.sourceFingerprint(fileID: fileID, line: line, column: column)
        return FreerMonad.impure(operation:
            .classify(
                gen: gen.erase(),
                fingerprint: fingerprint,
                classifiers: classifiers.map { pair in
                    (pair.0, { pair.1($0 as! Output) })
                }
            )
        ) { .pure($0 as! Output) }.wrapped
    }
}
