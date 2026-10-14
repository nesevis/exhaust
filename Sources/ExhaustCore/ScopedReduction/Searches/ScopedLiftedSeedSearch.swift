//
//  ScopedLiftedSeedSearch.swift
//  Exhaust
//

// MARK: - Lifted Seed Search

/// Emits a lifted sequence once, then optionally covers its bound range.
///
/// Keeping the seed and its covering in one search means scheduling and search accounting cannot introduce a boundary between them. Every candidate reports the proposal's mutation.
struct ScopedLiftedSeedSearch: ScopedSearch {
    private let mutation: EncoderProbe
    private var pending: ChoiceSequence?
    private var covering: ScopedCoveringRows

    /// - Parameter boundRange: The lifted bound range to cover after the seed; nil emits the seed alone.
    init(
        mutation: EncoderProbe,
        lifted: ChoiceSequence,
        boundRange: ClosedRange<Int>? = nil,
        tuning: ScopedReductionTuning
    ) {
        self.mutation = mutation
        covering = ScopedCoveringRows(tuning: tuning)
        pending = lifted
        if let boundRange {
            covering.start(sequence: lifted, positionRange: boundRange)
        }
    }

    mutating func next(_ feedback: ScopedSearchFeedback, into buffer: inout ChoiceSequence) -> ScopedCandidate? {
        if let pending {
            self.pending = nil
            buffer = pending
            return .written(mutation: mutation, admission: .standard)
        }
        guard let probe = covering.nextProbe(lastAccepted: feedback.isAccepted) else {
            return nil
        }
        buffer = probe
        return .written(mutation: mutation, admission: .standard)
    }

    consuming func finish(reason _: ScopedStopReason, undelivered _: ScopedSearchFeedback?) -> ScopedSearchReport {
        ScopedSearchReport()
    }
}
