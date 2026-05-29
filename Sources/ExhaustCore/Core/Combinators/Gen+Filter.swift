package extension Gen {
    /// Restricts a generator to values satisfying a predicate.
    ///
    /// For ``FilterType/choiceGradientSampling`` and ``FilterType/auto``, the generation interpreters tune the inner generator via CGS the first time the filter is encountered and memoize the result in a process-wide cache keyed by the source fingerprint, so each filter is tuned at most once per process. Reduction and replay interpreters use the untuned base generator directly.
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

        // Tuning is resolved lazily by the generation interpreters via the shared cache (``GenerationContext/resolveTunedFilter(fingerprint:generator:predicate:type:)``); construction only records the operation, seeded deterministically from the source fingerprint when it is tuned.
        return .impure(
            operation: .filter(
                gen: erased,
                fingerprint: fingerprint,
                filterType: type,
                predicate: erasedPredicate,
                sourceLocation: sourceLocation
            ),
            continuation: { .pure($0 as! Output) }
        )
    }

    /// Tunes a filtered generator according to its ``FilterType``, seeded deterministically from `seed`.
    ///
    /// Both the construction-time path (``filter(_:type:predicate:sourceLocation:)``) and the interpreters' deferred per-run cache call through this single point, so the strategy dispatch and the seed cannot drift between them. Seeding from a stable per-site value (the source fingerprint) rather than system randomness keeps the baked weights — and therefore generation — reproducible for a given run seed. Returns the input generator unchanged for ``FilterType/rejectionSampling`` or if a tuning pass throws.
    static func tuneFilter(
        _ generator: AnyGenerator,
        predicate: @escaping (Any) -> Bool,
        type: FilterType,
        seed: UInt64
    ) -> AnyGenerator {
        switch type {
            case .rejectionSampling:
                generator
            case .auto, .choiceGradientSampling:
                (try? ChoiceGradientTuner<Any>.tune(generator, predicate: predicate, seed: seed)) ?? generator
            case .probeSampling:
                (try? GeneratorTuning.probeAndTune(generator, seed: seed, predicate: predicate)) ?? generator
            case let .customCGS(warmupRuns, sampleCount, subdivisionThresholds):
                (try? ChoiceGradientTuner<Any>.tune(
                    generator,
                    predicate: predicate,
                    warmupRuns: warmupRuns,
                    sampleCount: sampleCount,
                    seed: seed,
                    subdivisionThresholds: subdivisionThresholds
                )) ?? generator
        }
    }
}
