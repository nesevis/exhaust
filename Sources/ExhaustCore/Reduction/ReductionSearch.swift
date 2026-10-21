//
//  ReductionSearch.swift
//  Exhaust
//

// MARK: - Feedback

/// The outcome of a search's previous candidate, delivered with the request for its next one.
///
/// It carries sequences but not the graph: a search that continues after an acceptance works from the sequence alone.
enum SearchFeedback {
    /// No candidate has been evaluated yet.
    case initial
    /// The candidate was committed; `recovered` is the incumbent's sequence after decoding, which can differ from the candidate. A search that continues from it builds on what was committed.
    case accepted(recovered: ChoiceSequence)
    case rejected(CandidateRejection)

    /// Whether the previous candidate was committed.
    var isAccepted: Bool {
        switch self {
            case .accepted:
                true
            case .initial, .rejected:
                false
        }
    }
}

/// Why a candidate was not committed.
enum CandidateRejection {
    case cached
    case materializationRejected
    case propertyPassed
    /// The property still failed, but decoding returned no counterexample or one the encoder's ``ReductionOrder`` does not admit.
    case failedNotAdmitted
    /// The outcome withheld, for searches whose composition cannot guarantee that attempts emit disjoint candidates.
    case undifferentiated
}

/// Why a candidate ended its search, and with it the pass.
enum SearchStopReason {
    /// The accepted candidate invalidated the graph or lifted context needed for further exploration. The runner must rebuild before another pass.
    case graphInvalidated
    /// The deadline passed before the candidate was decoded.
    case deadline
}

/// One unlifted search's share of a pass's probe counts.
struct SearchCounts: Equatable {
    /// The number of leaves each candidate moves when the search is a staged joint stage, which the runner attributes counts to. Nil for every other search.
    let stagedJointArity: Int?
    let counts: ReductionProbeCounts
}

/// Search knowledge a search hands back when it finishes.
struct SearchReport {
    /// Convergence records keyed by graph node ID, which the runner writes into the graph so later value searches warm-start from them.
    var convergenceRecords: [Int: ConvergedOrigin] = [:]
    /// Whether a replacement candidate was dropped for not preceding the base sequence. The runner uses it to schedule a relax round, which can try the replacement without the ordering.
    var hadUnresolvedReplacement = false
    /// The number of leaves each candidate moves when the search is a staged joint stage, which the runner attributes the search's counts to. Nil for every other search.
    var stagedJointArity: Int?
}

// MARK: - Candidate

/// A search's next candidate. The complete candidate is in the interpreter's buffer, or described as sparse edits that the interpreter hashes against the rejection cache before writing.
///
/// Each candidate carries its own admission, so a search can vary the checks decoding applies from one candidate to the next.
enum ReductionCandidate {
    case written(mutation: ProjectedMutation, admission: DecoderAdmission)
    case sparse(SparseEncoderProbe, baseSequence: ChoiceSequence, admission: DecoderAdmission)
}

// MARK: - Search Protocol

/// A feedback-driven candidate stream for one scope.
///
/// Searches keep their own state and write into a buffer the interpreter owns, so a pull allocates no sequence.
protocol ReductionSearch {
    /// Produces the next candidate, given the outcome of the previous one.
    mutating func next(_ feedback: SearchFeedback, into buffer: inout ChoiceSequence) -> ReductionCandidate?

    /// Flushes partial search knowledge. Called exactly once, when the search ends. `pending` is the outcome of the last candidate when the search ended before it could receive it, and ``SearchFeedback/initial`` otherwise.
    consuming func finish(pending: SearchFeedback) -> SearchReport
}

extension ReductionSearch {
    consuming func finish(pending _: SearchFeedback) -> SearchReport {
        SearchReport()
    }
}
