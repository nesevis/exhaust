extension Materializer {
    /// Regenerates a lifted proposal with the parent tree available for guided fallback and all branch alternatives retained. Accounting belongs to the caller, immediately before this invocation.
    ///
    /// A non-nil ceiling rejects oversized scalar arrays before element generation and checks the full history afterwards. Intermediate composition stages must omit it so downstream controllers can compensate for growth.
    static func guidedLift(
        generator: AnyGenerator,
        prefix: ChoiceSequence,
        fallbackTree: ChoiceTree,
        maximumSequenceCount: Int? = nil
    ) -> ChoiceTree? {
        guard case let .success(_, tree, _) = materializeAny(
            generator,
            context: .init(
                prefix: prefix,
                mode: .guided(seed: 0, fallbackTree: fallbackTree),
                fallbackTree: fallbackTree,
                materializePicks: true,
                maximumSequenceCount: maximumSequenceCount
            )
        ) else {
            return nil
        }
        guard SequenceCeiling(maximumCount: maximumSequenceCount).admits(tree: tree) else {
            return nil
        }
        return tree
    }
}
