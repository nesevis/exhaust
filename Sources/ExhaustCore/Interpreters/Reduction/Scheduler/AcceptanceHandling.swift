/// Keeps decoder selection independent of how an accepted mutation updates the live graph. Both paths must stop stale lifted searches from resuming after acceptance.
enum AcceptanceHandling: Equatable {
    /// Requests a rebuild without applying the reported mutation, then refreshes the encoder and keeps the session running. Composed encoders discard their pre-acceptance stages on refresh; ``GraphWindowRemovalEncoder`` keeps its stepper, because its probes are built from the dispatch-time base and stay valid after acceptance.
    case refreshAndIdle
    /// Applies the mutation to the live graph. A required full rebuild finishes the session rather than resuming its encoder.
    case applyMutation
}
