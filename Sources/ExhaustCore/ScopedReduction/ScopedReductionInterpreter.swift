//
//  ScopedReductionInterpreter.swift
//  Exhaust
//

// MARK: - Pass Report

/// Everything one execution observed, harvested by the interpreter rather than reported by programs.
struct ScopedPassReport {
    var counts = ReductionProbeCounts()
    var anyAccepted = false
    var anyRequiresRebuild = false
    var latestTreeIsStripped = false
    var acceptedLeafNodeIDs: Set<Int> = []
    /// From searches run at the top level. Searches inside a `propose` are finished and their reports discarded, since their node IDs belong to a lifted graph.
    var searchReport = ScopedSearchReport()
    /// Each top-level search's share of ``counts``, in the order the searches ran. Searches inside a `propose` are counted only in ``counts``.
    var searchCounts: [ScopedSearchCounts] = []
    /// Lift requests, including those whose materialization failed.
    var liftAttempts = 0
    /// Searches constructed by the outermost `propose`, including empty ones.
    var constructedSearches = 0
    /// Searches constructed by nested `propose` levels.
    var nestedConstructedSearches = 0
    var buildFailures: [DownstreamBuildFailure: Int] = [:]
    /// Lift attempts at levels the bound value build tally covers.
    var boundValueLiftAttempts = 0
    /// Build outcomes at levels the bound value build tally covers.
    var boundValueBuildOutcomes: [BoundValueBuildRecord: Int] = [:]
}

// MARK: - Interpreter

/// Executes one scope's program against a context the runner seeds.
///
/// Holds no decoding logic: it pulls candidates from searches, checks the rejection cache, asks the decoder to decode it, checks the result's ordering against the incumbent, and feeds the outcome back. Inside a `propose` it schedules searches in turns: a new branch is built before any suspended search resumes, suspended searches resume in FIFO order with a fresh turn, and the first acceptance ends every search. A branch whose pipeline reaches another `propose` becomes a nested level, which its parent schedules like any other search; a nested level's turn counts the parent's probes.
enum ScopedReductionInterpreter {
    /// What an execution hands back to the runner.
    struct Result {
        let incumbent: ScopedCounterexample
        let graph: ChoiceGraph
        let rejectCache: Set<UInt64>
        let report: ScopedPassReport
        /// The encode and decode time the execution spent, when the runner asked for it.
        let probeTiming: ProbeTiming?
    }

    /// Runs `program` until it finishes or the pass ends, and returns the restorable state with everything the execution observed.
    static func run(_ program: ScopedReducer, context: consuming Context) -> Result {
        _ = interpret(program, context: &context)
        return Result(
            incumbent: context.incumbent,
            graph: context.graph,
            rejectCache: context.rejectCache,
            report: context.report,
            probeTiming: context.probeTiming
        )
    }

    /// Answers the program's next request and continues with the program its continuation returns.
    ///
    /// - Returns: Why the pass ended, or nil when the program finished without ending it. A deadline, or an acceptance that ends the search, stops the program at the request that observed it, and its continuation never runs.
    static func interpret(_ program: ScopedReducer, context: inout Context) -> ScopedStopReason? {
        switch program {
            case .pure:
                return nil
            case let .impure(.lift(prefix, fallbackTree, maximumSequenceCount), continuation):
                return handleLift(
                    prefix,
                    fallbackTree: fallbackTree,
                    maximumSequenceCount: maximumSequenceCount,
                    continuation: continuation,
                    context: &context
                )
            case let .impure(.fail(reason), _):
                return handleFail(reason, context: &context)
            case let .impure(.search(box, configuration), continuation):
                return handleSearch(box, configuration: configuration, continuation: continuation, context: &context)
            case let .impure(.propose(branches, configuration), continuation):
                return handlePropose(branches, configuration: configuration, continuation: continuation, context: &context)
        }
    }
}

// MARK: - Context

extension ScopedReductionInterpreter {
    /// Owns one execution's collaborators and mutable state. ``run(_:context:)`` consumes it, so an execution's buffers and accounting cannot leak into the next.
    struct Context: ~Copyable {
        let decoder: ScopedDecoder
        let encoderName: EncoderName
        let isInstrumented: Bool
        let observer: ((ProbeObservation) -> Void)?
        /// Checked before each encode and before each decode.
        let deadlineCheck: (() -> Bool)?

        var incumbent: ScopedCounterexample
        var graph: ChoiceGraph
        var rejectCache: Set<UInt64>
        var report = ScopedPassReport()
        var baseHash: UInt64
        var candidateBuffer: ChoiceSequence
        var previousSparseProbe: SparseEncoderProbe?
        var nextProbeID = 0
        /// Builds left to a nested chain, shared by every level that has chain limits. Created by the outermost such level.
        var buildPoolRemaining: Int?
        var probeTiming: ProbeTiming?

        init(
            incumbent: ScopedCounterexample,
            graph: ChoiceGraph,
            rejectCache: Set<UInt64>,
            decoder: ScopedDecoder,
            encoderName: EncoderName,
            isInstrumented: Bool = false,
            deadlineCheck: (() -> Bool)? = nil,
            observer: ((ProbeObservation) -> Void)? = nil,
            timingMark: UInt64? = nil
        ) {
            self.incumbent = incumbent
            self.graph = graph
            self.rejectCache = rejectCache
            self.decoder = decoder
            self.encoderName = encoderName
            self.isInstrumented = isInstrumented
            self.deadlineCheck = deadlineCheck
            self.observer = observer
            baseHash = ZobristHash.hash(of: incumbent.sequence)
            candidateBuffer = incumbent.sequence
            probeTiming = timingMark.map { ProbeTiming(mark: $0) }
        }

        var isExpired: Bool {
            deadlineCheck?() == true
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
