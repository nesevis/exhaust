/// Keeps decoder selection independent of how an accepted mutation updates the live graph. Both paths must stop stale lifted searches from resuming after acceptance.
enum AcceptanceHandling: Equatable {
    /// Requests a rebuild without applying the reported mutation, then refreshes the encoder to discard its pre-acceptance stages.
    case refreshAndIdle
    /// Applies the mutation to the live graph. A required full rebuild finishes the session rather than resuming its encoder.
    case applyMutation
}
