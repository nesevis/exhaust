extension Materializer {
    /// Regenerates a lifted proposal with the parent tree available for guided fallback and all branch alternatives retained. Accounting belongs to the caller, immediately before this invocation.
    static func guidedLift(
        generator: AnyGenerator,
        prefix: ChoiceSequence,
        fallbackTree: ChoiceTree
    ) -> ChoiceTree? {
        guard case let .success(_, tree, _) = materializeAny(
            generator,
            context: .init(
                prefix: prefix,
                mode: .guided(seed: 0, fallbackTree: fallbackTree),
                fallbackTree: fallbackTree,
                materializePicks: true
            )
        ) else {
            return nil
        }
        return tree
    }
}
