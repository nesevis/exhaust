//
//  ScopedReductionInterpreter.swift
//  Exhaust
//

// MARK: - Pass Report

/// Everything one execution observed, harvested by the interpreter rather than reported by the encoder's reducer.
struct ScopedPassReport {
    var counts = ReductionProbeCounts()
    var anyAccepted = false
    /// Whether an acceptance left the graph needing a full rebuild, because its acceptance policy or its mutation ruled out an in-place update.
    var anyRequiresRebuild = false
    /// Whether the latest accepted decoding skipped materializing unselected branches, so the incumbent's tree lacks them and pick nodes cannot offer pivots.
    var latestTreeIsStripped = false
    /// Leaves an accepted `.leafValues` mutation changed. Their old-graph values are stale, so their convergence records transfer across the rebuild without the value guard.
    var acceptedLeafNodeIDs: Set<Int> = []
    /// From searches the root branch reaches. Searches inside a `propose` are finished and their reports discarded, since their node IDs belong to a lifted graph.
    var searchReport = ScopedSearchReport()
    /// Each root search's share of ``counts``, in the order the searches ran, for every one that was asked for a candidate. Searches inside a `propose` are counted only in ``counts``.
    var searchCounts: [ScopedSearchCounts] = []
    /// Lift requests, including those whose materialization failed.
    var liftAttempts = 0
    /// Searches constructed by the outermost `propose`, including empty ones.
    var constructedSearches = 0
    /// Searches constructed by nested `propose` levels.
    var nestedConstructedSearches = 0
    /// What each `propose` branch built after its lifts, and every failure, by how many `propose` levels enclose it.
    var buildOutcomes: [CompositionBuildRecord: Int] = [:]
}

// MARK: - Interpreter

/// Executes the encoder's reducer for one scope against a context the runner seeds.
///
/// Holds no decoding logic: it asks searches for candidates, checks each against the rejection cache, has the decoder decode it, checks the result's ordering against the incumbent, and feeds the outcome back.
///
/// Inside a `propose` it selects the branch with the smallest cost plus emitted candidate count, breaking ties by original branch order. Branches are built only when selected. The optional turn-based policy builds new branches before resuming suspended searches in FIFO order. An acceptance that ends its search, under ``ScopedAcceptance/stop`` or through a rebuild, ends every search in the pass. A branch whose pipeline reaches another `propose` becomes a nested level, scheduled like any other search: each candidate it emits advances its parent's grade, while its own priorities stay local to the child pool.
enum ScopedReductionInterpreter {
    /// What an execution hands back to the runner.
    struct Result {
        let incumbent: ScopedCounterexample
        /// The hash of ``incumbent``'s sequence, kept up to date by every commit, so the runner need not hash it again.
        let incumbentHash: UInt64
        let graph: ChoiceGraph
        let rejectCache: ScopedProbeCache
        let report: ScopedPassReport
        /// The encode and decode time the execution spent, when the runner asked for it.
        let probeTiming: ProbeTiming?
    }

    /// Builds the encoder's reducer as the root branch and evaluates its candidates until the reducer finishes, the deadline passes, or an acceptance ends the pass, and returns the restorable state with everything the execution observed.
    ///
    /// The root is built without recording a build outcome. A search it reaches keeps its report and records its own counts; a `propose` it reaches becomes the outermost level.
    static func reduce(_ reducer: ScopedReducer, context: consuming Context) -> Result {
        if case let .built(root) = buildBranch(reducer, depth: nil, context: &context) {
            var pool = ScopedSearchPool(root: root)
            evaluating: while true {
                switch next(&pool, checksDeadline: true, context: &context) {
                    case .exhausted:
                        break evaluating
                    case .deadline, .budgetExhausted:
                        finishAll(&pool, context: &context)
                        break evaluating
                    case let .emitted(evaluation):
                        if evaluation.stop != nil {
                            break evaluating
                        }
                }
            }
        }
        return Result(
            incumbent: context.incumbent,
            incumbentHash: context.baseHash,
            graph: context.graph,
            rejectCache: context.rejectCache,
            report: context.report,
            probeTiming: context.probeTiming
        )
    }
}

// MARK: - Context

extension ScopedReductionInterpreter {
    /// Owns one execution's collaborators and mutable state. ``reduce(_:context:)`` consumes it, so an execution's buffers and accounting cannot leak into the next.
    struct Context: ~Copyable {
        let decoder: ScopedDecoder
        /// The encoder whose reducer runs, for its admission order and its name in logs.
        let encoder: any ScopedEncoder.Type
        let isInstrumented: Bool
        let observer: ((ProbeObservation) -> Void)?
        /// Checked before each encode and before each decode.
        let deadline: ScopedDeadline

        var incumbent: ScopedCounterexample
        var graph: ChoiceGraph
        var rejectCache: ScopedProbeCache
        var report = ScopedPassReport()
        var baseHash: UInt64
        var candidateBuffer: ChoiceSequence
        var previousSparseProbe: SparseEncoderProbe?
        var nextProbeID = 0
        /// Builds left to a nested chain, shared by every level that has chain limits. Created by the outermost such level.
        var buildPoolRemaining: Int?
        var probeTiming: ProbeTiming?

        /// - Parameter incumbentHash: The Zobrist hash of `incumbent`'s sequence, which the runner keeps rather than rehashing per pass.
        init(
            incumbent: ScopedCounterexample,
            incumbentHash: UInt64,
            graph: ChoiceGraph,
            rejectCache: ScopedProbeCache,
            decoder: ScopedDecoder,
            encoder: any ScopedEncoder.Type,
            isInstrumented: Bool = false,
            deadline: ScopedDeadline = .none,
            observer: ((ProbeObservation) -> Void)? = nil,
            timingMark: UInt64? = nil
        ) {
            self.incumbent = incumbent
            self.graph = graph
            self.rejectCache = rejectCache
            self.decoder = decoder
            self.encoder = encoder
            self.isInstrumented = isInstrumented
            self.deadline = deadline
            self.observer = observer
            baseHash = incumbentHash
            candidateBuffer = incumbent.sequence
            probeTiming = timingMark.map { ProbeTiming(mark: $0) }
        }

        var isExpired: Bool {
            deadline.isExpired
        }
    }
}

// MARK: - Probe Timing

extension ScopedReductionInterpreter {
    /// Splits an execution's time into encode and decode spans. Each span runs from the previous charge, starting at the runner's `mark`, so the time a search spends producing a candidate, rejection cache check included, is encode time, and decoding with whatever commit or rejection follows is decode time.
    struct ProbeTiming {
        /// When the last span ended. The runner resumes its own accounting from here.
        var mark: UInt64
        var encodeNanoseconds: UInt64 = 0
        var decodeNanoseconds: UInt64 = 0
        var encodeCount = 0
        var decodeCount = 0

        mutating func chargeEncode() {
            let now = MonotonicClock.nanoseconds()
            encodeNanoseconds += now - mark
            encodeCount += 1
            mark = now
        }

        mutating func chargeDecode() {
            let now = MonotonicClock.nanoseconds()
            decodeNanoseconds += now - mark
            decodeCount += 1
            mark = now
        }
    }
}
