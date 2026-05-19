package extension Gen {
    /// Restricts a generator to values satisfying a predicate.
    ///
    /// For ``FilterType/choiceGradientSampling`` and ``FilterType/auto``, eagerly tunes the inner generator via CGS warmup at construction time so generation interpreters pay no tuning cost per invocation. When constructed inside an interpreter bind continuation (``isInterpreting`` is true), tuning is deferred to the interpreter's fingerprint-keyed cache instead.
    ///
    /// - Parameters:
    ///   - generator: The base generator to filter.
    ///   - type: Strategy for satisfying the predicate.
    ///   - predicate: Validity condition that generated values must satisfy.
    ///   - sourceLocation: Source location of the call site for diagnostic warnings.
    /// - Returns: A filtered generator that only produces valid values.
    static func filter<Output>(
        _ generator: Generator<Output>,
        type: FilterType = .auto,
        predicate: @escaping (Output) -> Bool,
        sourceLocation: FilterSourceLocation
    ) -> Generator<Output> {
        let erased = generator.erase()
        let erasedPredicate: (Any) -> Bool = { predicate($0 as! Output) }
        let fingerprint = Gen.sourceFingerprint(
            fileID: sourceLocation.fileID,
            line: sourceLocation.line,
            column: sourceLocation.column
        )

        let isInterpreting = Gen.isInterpreting
        let tuned: AnyGenerator?
        switch (type, isInterpreting) {
        case (.rejectionSampling, _),
             (.choiceGradientSampling, true),
             (.auto, true),
             (.probeSampling, true),
             (.customCGS, true):
            tuned = nil
        case (.choiceGradientSampling, false), (.auto, false):
            tuned = try? ChoiceGradientTuner<Any>.tune(
                erased,
                predicate: erasedPredicate
            )
        case (.probeSampling, false):
            tuned = try? GeneratorTuning.probeAndTune(
                erased,
                predicate: erasedPredicate
            )
        case let (.customCGS(warmupRuns, sampleCount, subdivisionThresholds), false):
            tuned = try? ChoiceGradientTuner<Any>.tune(
                erased,
                predicate: erasedPredicate,
                warmupRuns: warmupRuns,
                sampleCount: sampleCount,
                subdivisionThresholds: subdivisionThresholds
            )
        }

        return .impure(
            operation: .filter(
                gen: erased,
                fingerprint: fingerprint,
                filterType: type,
                predicate: erasedPredicate,
                tuned: tuned,
                sourceLocation: sourceLocation
            ),
            continuation: { .pure($0 as! Output) }
        )
    }
}
