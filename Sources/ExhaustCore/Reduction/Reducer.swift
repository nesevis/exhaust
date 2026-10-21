//
//  Reducer.swift
//  Exhaust
//

// MARK: - Pass Report

/// Everything one execution observed, harvested by the interpreter rather than reported by the encoder's reduction.
struct ReductionPassReport {
    var counts = ReductionProbeCounts()
    var anyAccepted = false
    /// Whether an acceptance left the graph needing a full rebuild, because a lift, its acceptance policy, or its mutation ruled out an in-place update.
    var anyRequiresRebuild = false
    /// Whether the latest accepted decoding skipped materializing unselected branches, so the incumbent's tree lacks them and pick nodes cannot offer pivots.
    var latestTreeIsStripped = false
    /// Leaves an accepted `.leafValues` mutation changed. Their old-graph values are stale, so their convergence records transfer across the rebuild without the value guard.
    var acceptedLeafNodeIDs: Set<Int> = []
    /// From searches that address the incumbent graph. Searches in lifted context are finished and their reports discarded, since their node IDs belong to another graph.
    var searchReport = SearchReport()
    /// Each unlifted search's share of ``counts``, in completion order, for every one that was asked for a candidate. Lifted searches are counted only in ``counts``.
    var searchCounts: [SearchCounts] = []
    /// Lift requests, including those whose materialization failed.
    var liftAttempts = 0
    /// Attempts constructed by outermost `propose` levels, each counted once on reaching a search or nested level, even if it emits no probes. The root attempt and failed builds are excluded.
    var constructedAttempts = 0
    /// Attempts constructed by nested `propose` levels, counted on the same basis as ``constructedAttempts``.
    var nestedConstructedAttempts = 0
    /// What each `propose` attempt built after its lifts, and every failure, by how many `propose` levels enclose it.
    var buildOutcomes: [CompositionBuildRecord: Int] = [:]
}

// MARK: - Interpreter

/// Executes the encoder's reduction for one scope against a context the runner seeds.
///
/// Holds no decoding logic: it asks searches for candidates, checks each against the rejection cache, has the decoder decode it, checks the result's ordering against the incumbent, and feeds the outcome back.
///
/// Inside a `propose` it selects the attempt with the smallest cost plus emitted candidate count, breaking ties by original attempt order. Attempts are built only when selected. The optional turn-based policy builds new attempts before resuming suspended attempts in FIFO order. An acceptance that ends its search, in lifted context or through a rebuild, ends every search in the pass. An attempt whose pipeline reaches another `propose` becomes a nested level, scheduled as part of that attempt: each candidate it emits advances its parent's grade, while its own priorities stay local to the child pool.
enum Reducer {
    /// What an execution hands back to the runner.
    struct Result {
        let incumbent: Counterexample
        /// The hash of ``incumbent``'s sequence, kept up to date by every commit, so the runner need not hash it again.
        let incumbentHash: UInt64
        let graph: ChoiceGraph
        let rejectCache: ProbeCache
        let report: ReductionPassReport
        /// The encode and decode time the execution spent, when the runner asked for it.
        let probeTiming: ProbeTiming?
    }

    /// Builds the encoder's reduction as the root attempt and evaluates its candidates until the reduction finishes, the deadline passes, or an acceptance ends the pass, and returns the restorable state with everything the execution observed.
    ///
    /// The root is built without recording a build outcome; a `propose` it reaches becomes the outermost level. Search reports are kept only while searches address the incumbent graph.
    static func reduce(_ reduction: Reduction, context: consuming Context) -> Result {
        if case let .built(root) = buildAttempt(reduction, depth: nil, context: &context) {
            let pool = AttemptPool(root: root)
            evaluating: while true {
                switch next(pool, checksDeadline: true, context: &context) {
                    case .exhausted:
                        break evaluating
                    case .deadline, .budgetExhausted:
                        finishAll(pool, context: &context)
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

extension Reducer {
    /// Owns one execution's collaborators and mutable state. ``reduce(_:context:)`` consumes it, so an execution's buffers and accounting cannot leak into the next.
    struct Context: ~Copyable {
        let decoder: ReductionDecoder
        /// The encoder whose reduction runs, for its admission order and its name in logs.
        let encoder: any ReductionEncoder.Type
        let isInstrumented: Bool
        let observer: ((ProbeObservation) -> Void)?
        /// Checked before each encode and before each decode.
        let deadline: ReductionDeadline

        var incumbent: Counterexample
        var graph: ChoiceGraph
        var rejectCache: ProbeCache
        var report = ReductionPassReport()
        var baseHash: UInt64
        var candidateBuffer: ChoiceSequence
        var previousSparseProbe: SparseEncoderProbe?
        var nextProbeID = 0
        /// Builds left to a nested chain, shared by every level that has chain limits. Created by the outermost such level.
        var buildPoolRemaining: Int?
        var probeTiming: ProbeTiming?

        /// - Parameter incumbentHash: The Zobrist hash of `incumbent`'s sequence, which the runner keeps rather than rehashing per pass.
        init(
            incumbent: Counterexample,
            incumbentHash: UInt64,
            graph: ChoiceGraph,
            rejectCache: ProbeCache,
            decoder: ReductionDecoder,
            encoder: any ReductionEncoder.Type,
            isInstrumented: Bool = false,
            deadline: ReductionDeadline = .none,
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

extension Reducer {
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
