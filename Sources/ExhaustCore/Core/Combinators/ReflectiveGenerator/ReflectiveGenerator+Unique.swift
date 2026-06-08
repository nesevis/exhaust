//
//  ReflectiveGenerator+Unique.swift
//  Exhaust
//
//  Created by Chris Kolbu on 13/5/2026.
//

public extension ReflectiveGenerator {
    /// Creates a generator that only produces unique values, deduplicated by choice sequence.
    ///
    /// Each generated value's underlying choice sequence is tracked. If a duplicate choice sequence is encountered, the generator retries (up to `maxFilterRuns` from the interpreter context). This is useful when the generator's domain is large but you want to avoid repeating the same random path.
    ///
    /// Unlike `.filter`, `.unique` does not trigger ``FilterType/choiceGradientSampling`` tuning of the inner generator, because the deduplication predicate is stateful (it depends on what has been seen so far) and cannot be learned during a warmup pass. If `.unique()` is slow or exhausts its retry budget, the inner generator likely has a sparse validity condition that should be made explicit.
    /// Apply `.filter` *before* `.unique` so that the choice-gradient tuner can learn the static predicate and bias pick weights toward valid outputs:
    ///
    /// ```swift
    /// // Slow — .unique() retries blindly against a sparse validity space
    /// #gen(.binaryTree()).unique()
    ///
    /// // Fast — .filter() triggers .choiceGradientSampling, then .unique() deduplicates
    /// #gen(.binaryTree())
    ///     .filter { $0.isValidBST() }
    ///     .unique()
    /// ```
    ///
    /// - Parameters:
    ///   - fileID: Source file identifier for fingerprinting (auto-captured).
    ///   - line: Source line number for fingerprinting (auto-captured).
    ///   - column: Source column for fingerprinting (auto-captured).
    /// - Returns: A generator that only yields values with unique choice sequences.
    func unique(
        fileID: StaticString = #fileID,
        line: UInt = #line,
        column: UInt = #column
    ) -> ReflectiveGenerator<Output> {
        let fingerprint = Gen.sourceFingerprint(fileID: fileID, line: line, column: column)
        return FreerMonad.impure(
            operation: .unique(
                gen: gen.erase(),
                fingerprint: fingerprint,
                keyExtractor: nil
            )
        ) { .pure($0 as! Output) }.wrapped
    }

    /// Creates a generator that only produces unique values, deduplicated by a hashable key path.
    ///
    /// The value extracted by the key path is used as the deduplication key. Two values are considered duplicates if they produce the same key.
    ///
    /// ```swift
    /// let gen = #gen(.element(from: configs, id: \.id)).unique(by: \.id)
    /// ```
    ///
    /// - Parameters:
    ///   - by: A key path to the hashable property used for deduplication.
    ///   - fileID: Source file identifier for fingerprinting (auto-captured).
    ///   - line: Source line number for fingerprinting (auto-captured).
    ///   - column: Source column for fingerprinting (auto-captured).
    /// - Returns: A generator that only yields values with unique keys.
    func unique(
        by path: KeyPath<Output, some Hashable> & Sendable,
        fileID: StaticString = #fileID,
        line: UInt = #line,
        column: UInt = #column
    ) -> ReflectiveGenerator<Output> {
        unique(
            by: { value in
                AnyHashable(value[keyPath: path])
            },
            fileID: fileID,
            line: line,
            column: column
        )
    }

    /// Creates a generator that only produces unique values, deduplicated by a transform.
    ///
    /// The transform function extracts a hashable key from each generated value.
    /// Two values are considered duplicates if they produce the same key.
    ///
    /// - Parameters:
    ///   - transform: A function that extracts a hashable key from the generated value.
    ///   - fileID: Source file identifier for fingerprinting (auto-captured).
    ///   - line: Source line number for fingerprinting (auto-captured).
    /// - Returns: A generator that only yields values with unique keys.
    func unique(
        by transform: @Sendable @escaping (Output) -> some Hashable,
        fileID: StaticString = #fileID,
        line: UInt = #line,
        column: UInt = #column
    ) -> ReflectiveGenerator<Output> {
        let fingerprint = Gen.sourceFingerprint(fileID: fileID, line: line, column: column)
        return FreerMonad.impure(
            operation: .unique(
                gen: gen.erase(),
                fingerprint: fingerprint,
                keyExtractor: { value in
                    AnyHashable(transform(value as! Output))
                }
            )
        ) { .pure($0 as! Output) }.wrapped
    }
}
