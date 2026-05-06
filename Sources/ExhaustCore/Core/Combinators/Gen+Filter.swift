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

        let tuned: ReflectiveGenerator<Any>?
        switch type {
        case .rejectionSampling:
            tuned = nil
        case .choiceGradientSampling, .auto:
            tuned = try? ChoiceGradientTuner<Any>.tune(
                erased,
                predicate: erasedPredicate
            )
        case .probeSampling:
            tuned = try? GeneratorTuning.probeAndTune(
                erased,
                predicate: erasedPredicate
            )
        }

        return .impure(
            operation: .filter(
                gen: erased,
                fingerprint: fingerprint,
                filterType: type,
                predicate: erasedPredicate,
                sourceLocation: sourceLocation,
                tuned: tuned
            ),
            continuation: { .pure($0 as! Output) }
        )
    }
}
