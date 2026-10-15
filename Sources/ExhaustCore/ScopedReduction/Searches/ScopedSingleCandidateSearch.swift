//
//  ScopedSingleCandidateSearch.swift
//  Exhaust
//

// MARK: - Single Candidate Search

/// Emits one prebuilt candidate, for scopes that fully determine their probe.
///
/// Built with no candidate when the scope yields none. A replacement whose candidate the ordering dropped reports ``ScopedSearchReport/hadUnresolvedReplacement``, so a relax round can try it without the ordering.
struct ScopedSingleCandidateSearch: ScopedSearch {
    private var pending: (candidate: ChoiceSequence, mutation: EncoderProbe)?
    private let hadUnresolvedReplacement: Bool

    init(candidate: ChoiceSequence, mutation: EncoderProbe) {
        self.init(pending: (candidate: candidate, mutation: mutation), hadUnresolvedReplacement: false)
    }

    /// A search with nothing to emit, for a scope that yields no candidate.
    init() {
        self.init(pending: nil, hadUnresolvedReplacement: false)
    }

    /// Emits a replacement candidate only when it precedes `base`. A candidate the ordering drops is reported as unresolved instead.
    static func replacement(_ candidate: ChoiceSequence?, mutation: EncoderProbe, base: ChoiceSequence) -> Self {
        guard let candidate else {
            return Self()
        }
        guard candidate.shortLexPrecedes(base) else {
            return Self(pending: nil, hadUnresolvedReplacement: true)
        }
        return Self(candidate: candidate, mutation: mutation)
    }

    private init(pending: (candidate: ChoiceSequence, mutation: EncoderProbe)?, hadUnresolvedReplacement: Bool) {
        self.pending = pending
        self.hadUnresolvedReplacement = hadUnresolvedReplacement
    }

    mutating func next(_: ScopedSearchFeedback, into buffer: inout ChoiceSequence) -> ScopedCandidate? {
        guard let emitted = pending else {
            return nil
        }
        pending = nil
        buffer = emitted.candidate
        return .written(mutation: emitted.mutation, admission: .standard)
    }

    consuming func finish(pending _: ScopedSearchFeedback) -> ScopedSearchReport {
        ScopedSearchReport(hadUnresolvedReplacement: hadUnresolvedReplacement)
    }
}
