//
//  ScopedSearch.swift
//  Exhaust
//

// MARK: - Feedback

/// The outcome of a search's previous candidate, delivered with the request for its next one.
///
/// It carries the recovered sequence but not the graph: a search that continues after an acceptance works from the sequence alone.
enum ScopedSearchFeedback {
    /// No candidate has been evaluated yet.
    case initial
    /// The candidate was committed; `recovered` is the incumbent's sequence after decoding.
    case accepted(recovered: ChoiceSequence)
    case rejected(ScopedRejection)

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
enum ScopedRejection {
    case cached
    case materializationRejected
    case propertyPassed
    case failedNotAdmitted
    /// The outcome withheld, for searches whose composition cannot guarantee that branches emit disjoint candidates.
    case undifferentiated
}

/// Why the interpreter stopped pulling from a search.
enum ScopedStopReason {
    /// The search returned nil.
    case exhausted
    /// An acceptance ended the search: ``ScopedAcceptance/stop``, or a rebuild under ``ScopedAcceptance/continue``.
    case accepted
    case deadline
    /// A probe cap stopped a search that still had candidates.
    case budgetExhausted
    case invalidated
}

/// One top-level search's share of a pass's probe counts.
struct ScopedSearchCounts: Equatable {
    /// The number of leaves each candidate moves when the search is a staged joint stage, which the runner attributes counts to. Nil for every other search.
    let stagedJointArity: Int?
    let counts: ReductionProbeCounts
}

/// Search knowledge a search hands back when it finishes.
struct ScopedSearchReport {
    var convergenceRecords: [Int: ConvergedOrigin] = [:]
    var hadUnresolvedReplacement = false
}

// MARK: - Candidate

/// A search's next candidate. The complete candidate is in the interpreter's buffer, or described as sparse edits that the interpreter hashes against the rejection cache before writing.
///
/// Each candidate carries its own admission, so a search can vary the checks decoding applies from one candidate to the next.
enum ScopedCandidate {
    case written(mutation: EncoderProbe, admission: DecoderAdmission)
    case sparse(SparseEncoderProbe, baseSequence: ChoiceSequence, admission: DecoderAdmission)
}

// MARK: - Search Protocol

/// A feedback-driven candidate stream for one scope.
///
/// Searches keep their own efficient search state and write into a buffer the interpreter owns, so a pull allocates no sequence.
protocol ScopedSearch {
    /// Produces the next candidate, given the outcome of the previous one.
    mutating func next(_ feedback: ScopedSearchFeedback, into buffer: inout ChoiceSequence) -> ScopedCandidate?

    /// Flushes partial search knowledge. Called exactly once, from the interpreter's single exit point, with the feedback for the last evaluated candidate when the search has not received it.
    consuming func finish(reason: ScopedStopReason, undelivered: ScopedSearchFeedback?) -> ScopedSearchReport
}

// MARK: - Registered Searches

/// Closed registration of search types, dispatched by `switch` so the per-candidate path opens no existentials.
enum ScopedSearchKind {
    case binarySearch(ScopedBinarySearch)
    case covering(ScopedCoveringSearch)
    case laneCollapse(ScopedLaneCollapseSearch)
    case integerSearch(ScopedIntegerSearch)
    case floatSearch(ScopedFloatSearch)
    case redistribution(ScopedRedistributionSearch)
    case lockstep(ScopedLockstepSearch)
    case relation(ScopedRelationSearch)
    case stagedJoint(ScopedStagedJointSearch)
    case singleCandidate(ScopedSingleCandidateSearch)
    case coveringAlignedRemoval(ScopedCoveringAlignedRemovalSearch)
    case windowRemoval(ScopedWindowRemovalSearch)
    case swap(ScopedSwapSearch)
    case reorder(ScopedReorderSearch)

    /// Consumes `self` before advancing, so the search's storage stays uniquely referenced and is not copied per candidate.
    mutating func next(_ feedback: ScopedSearchFeedback, into buffer: inout ChoiceSequence) -> ScopedCandidate? {
        switch consume self {
            case var .binarySearch(search):
                let candidate = search.next(feedback, into: &buffer)
                self = .binarySearch(search)
                return candidate
            case var .covering(search):
                let candidate = search.next(feedback, into: &buffer)
                self = .covering(search)
                return candidate
            case var .laneCollapse(search):
                let candidate = search.next(feedback, into: &buffer)
                self = .laneCollapse(search)
                return candidate
            case var .integerSearch(search):
                let candidate = search.next(feedback, into: &buffer)
                self = .integerSearch(search)
                return candidate
            case var .floatSearch(search):
                let candidate = search.next(feedback, into: &buffer)
                self = .floatSearch(search)
                return candidate
            case var .redistribution(search):
                let candidate = search.next(feedback, into: &buffer)
                self = .redistribution(search)
                return candidate
            case var .lockstep(search):
                let candidate = search.next(feedback, into: &buffer)
                self = .lockstep(search)
                return candidate
            case var .relation(search):
                let candidate = search.next(feedback, into: &buffer)
                self = .relation(search)
                return candidate
            case var .stagedJoint(search):
                let candidate = search.next(feedback, into: &buffer)
                self = .stagedJoint(search)
                return candidate
            case var .singleCandidate(search):
                let candidate = search.next(feedback, into: &buffer)
                self = .singleCandidate(search)
                return candidate
            case var .coveringAlignedRemoval(search):
                let candidate = search.next(feedback, into: &buffer)
                self = .coveringAlignedRemoval(search)
                return candidate
            case var .windowRemoval(search):
                let candidate = search.next(feedback, into: &buffer)
                self = .windowRemoval(search)
                return candidate
            case var .swap(search):
                let candidate = search.next(feedback, into: &buffer)
                self = .swap(search)
                return candidate
            case var .reorder(search):
                let candidate = search.next(feedback, into: &buffer)
                self = .reorder(search)
                return candidate
        }
    }

    consuming func finish(reason: ScopedStopReason, undelivered: ScopedSearchFeedback?) -> ScopedSearchReport {
        switch consume self {
            case let .binarySearch(search):
                search.finish(reason: reason, undelivered: undelivered)
            case let .covering(search):
                search.finish(reason: reason, undelivered: undelivered)
            case let .laneCollapse(search):
                search.finish(reason: reason, undelivered: undelivered)
            case let .integerSearch(search):
                search.finish(reason: reason, undelivered: undelivered)
            case let .floatSearch(search):
                search.finish(reason: reason, undelivered: undelivered)
            case let .redistribution(search):
                search.finish(reason: reason, undelivered: undelivered)
            case let .lockstep(search):
                search.finish(reason: reason, undelivered: undelivered)
            case let .relation(search):
                search.finish(reason: reason, undelivered: undelivered)
            case let .stagedJoint(search):
                search.finish(reason: reason, undelivered: undelivered)
            case let .singleCandidate(search):
                search.finish(reason: reason, undelivered: undelivered)
            case let .coveringAlignedRemoval(search):
                search.finish(reason: reason, undelivered: undelivered)
            case let .windowRemoval(search):
                search.finish(reason: reason, undelivered: undelivered)
            case let .swap(search):
                search.finish(reason: reason, undelivered: undelivered)
            case let .reorder(search):
                search.finish(reason: reason, undelivered: undelivered)
        }
    }
}
