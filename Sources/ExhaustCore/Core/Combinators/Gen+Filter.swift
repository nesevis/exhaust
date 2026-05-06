package extension Gen {
    /// Creates a generator that only produces values satisfying the given predicate.
    ///
    /// For ``FilterType/choiceGradientSampling`` and ``FilterType/auto``, eagerly tunes the inner generator via CGS warmup at construction time so that generation interpreters pay no tuning cost per invocation.
    ///
    /// - Parameters:
    ///   - generator: The base generator to filter.
    ///   - type: Strategy for satisfying the predicate.
    ///   - predicate: Validity condition that generated values must satisfy.
    ///   - sourceLocation: Source location of the call site for diagnostic warnings.
    /// - Returns: A filtered generator that only produces valid values.
    static func filter<Output>(
        _ generator: ReflectiveGenerator<Output>,
        type: FilterType = .auto,
        predicate: @escaping (Output) -> Bool,
        sourceLocation: FilterSourceLocation
    ) -> ReflectiveGenerator<Output> {
        let erased = generator.erase()
        let erasedPredicate: (Any) -> Bool = { predicate($0 as! Output) }
        let fingerprint = sourceLocation.fileID.description.hashValue.bitPattern64
            &+ sourceLocation.line.bitPattern64

        let isInterpreting = Gen.isInterpreting
        let tuned: ReflectiveGenerator<Any>?
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
