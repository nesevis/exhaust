//
//  ReductionStateTypes.swift
//  Exhaust
//
//  Created by Chris Kolbu on 25/3/2026.
//

// MARK: - Convergence Signal

/// Records what an encoder observed when it terminated, reported to the factory for cross-cycle decisions.
///
/// Each encoder produces a signal at convergence. The factory pattern-matches on the signal to select the recovery encoder for the next cycle. Signals are stored in ``ConvergedOrigin`` alongside the warm-start bound.
public enum ConvergenceSignal: Hashable, Sendable {
    /// Binary search converged normally. Monotonicity held throughout.
    case monotoneConvergence

    /// Binary search: the property passed at a value where the monotonicity assumption predicted failure. The failure surface has a gap — bounded scan below the convergence point may find a lower floor.
    case nonMonotoneGap(remainingRange: Int)

    /// Zero-value: batch zeroing failed but at least one individual zeroing succeeded. The coordinate has dependencies on other coordinates.
    case zeroingDependency

    /// Linear scan completed. The factory reverts to binary search on the next cycle.
    case scanComplete(foundLowerFloor: Bool)
}

// MARK: - Encoder Configuration

/// Identifies the encoder configuration that produced a convergence record.
///
/// The factory uses this to reject cache entries from a different configuration so that warm-start data from one encoder does not pollute another's search.
public enum EncoderConfiguration: Hashable, Sendable {
    case binarySearchSemanticSimplest
    case linearScan
    case zeroValue
}

// MARK: - Converged Origin

/// Stores the convergence bound and observation from a prior encoder pass.
///
/// Carries warm-start data (`bound`), the encoder's observation (`signal`), the configuration that produced it (`configuration`), and the cycle number for staleness detection. Stored in the ``ConvergenceCache`` and supplied to encoders via ``ReductionContext/convergedOrigins``.
public struct ConvergedOrigin: Sendable {
    /// The bit-pattern value at which the search converged. Warm-start data.
    public let bound: UInt64

    /// Describes what the encoder observed at convergence. Factory decision data.
    public let signal: ConvergenceSignal

    /// Identifies which encoder configuration produced this entry. Staleness discriminant.
    public let configuration: EncoderConfiguration

    /// The cycle in which this observation was recorded. Staleness detection.
    public let cycle: Int

    public init(
        bound: UInt64,
        signal: ConvergenceSignal,
        configuration: EncoderConfiguration,
        cycle: Int
    ) {
        self.bound = bound
        self.signal = signal
        self.configuration = configuration
        self.cycle = cycle
    }
}

// MARK: - Convergence Cache

/// Per-coordinate convergence cache for the reduction pipeline.
///
/// Records ``ConvergedOrigin`` entries from encoder convergence events. Fibre descent passes supply cached entries to binary search encoders to narrow (or skip) search ranges on subsequent cycles. Invalidated entirely on structural change.
struct ConvergenceCache {
    private var entries: [Int: ConvergedOrigin] = [:]

    @inline(__always)
    var isEmpty: Bool {
        entries.isEmpty
    }

    @inline(__always)
    func convergedOrigin(at index: Int) -> ConvergedOrigin? {
        entries[index]
    }

    /// Returns all cached entries, or `nil` if empty.
    var allEntries: [Int: ConvergedOrigin]? {
        entries.isEmpty ? nil : entries
    }

    @inline(__always)
    mutating func record(index: Int, convergedOrigin: ConvergedOrigin) {
        entries[index] = convergedOrigin
    }

    mutating func invalidateAll() {
        entries.removeAll(keepingCapacity: true)
    }

    /// Remaps entries from old positions to new positions after a pure deletion.
    ///
    /// Walks both sequences with two pointers. Matching entries at `old[i] == new[j]` produce a position mapping `i → j`. Entries at deleted positions are dropped. Falls back to ``invalidateAll()`` if the new sequence is not a strict subsequence of the old (insertion or replacement detected).
    mutating func remap(from oldSequence: ChoiceSequence, to newSequence: ChoiceSequence) {
        guard entries.isEmpty == false else { return }
        guard newSequence.count < oldSequence.count else {
            invalidateAll()
            return
        }

        var remapped: [Int: ConvergedOrigin] = [:]
        remapped.reserveCapacity(entries.count)
        var newIndex = 0

        for oldIndex in 0 ..< oldSequence.count {
            guard newIndex < newSequence.count else {
                // Remaining old entries are deleted — skip.
                break
            }
            if oldSequence[oldIndex] == newSequence[newIndex] {
                if let origin = entries[oldIndex] {
                    remapped[newIndex] = origin
                }
                newIndex += 1
            }
            // else: old[oldIndex] was deleted, advance old only.
        }

        // If we didn't consume all of newSequence, it's not a pure deletion — fall back.
        if newIndex < newSequence.count {
            invalidateAll()
            return
        }

        entries = remapped
    }

    /// Invalidates entries at positions where the value changed between two same-length sequences.
    ///
    /// After value-only changes (reorder, redistribution) the sequence length is unchanged but cached convergence bounds may reference a different value than what now occupies that position. This drops exactly those stale entries while preserving valid warm-start bounds at untouched positions.
    mutating func invalidateWhereMoved(from oldSequence: ChoiceSequence, to newSequence: ChoiceSequence) {
        guard entries.isEmpty == false else { return }
        for index in entries.keys {
            if oldSequence[index] != newSequence[index] {
                entries.removeValue(forKey: index)
            }
        }
    }

    /// Invalidates all entries whose index falls within the given range.
    mutating func invalidate(in range: ClosedRange<Int>) {
        for index in entries.keys where range.contains(index) {
            entries.removeValue(forKey: index)
        }
    }
}

// MARK: - Edge Observation

/// Describes what the downstream encoder observed about a composition edge's fibre.
///
/// Per-fibre signals from the downstream role. Stored per-edge on ``ReductionState``, keyed by region index. The factory reads these to skip fully-searched edges or adjust budgets.
enum FibreSignal: Hashable, Sendable {
    /// Exhaustive or pairwise search covered the full fibre. No failure found.
    case exhaustedClean

    /// Exhaustive or pairwise search covered the full fibre. At least one failure found.
    case exhaustedWithFailure

    /// The downstream encoder bailed before completing coverage.
    case bail(paramCount: Int)
}

/// Records the downstream observation for a composition edge after the edge completes.
struct EdgeObservation: Sendable {
    /// Describes what the downstream encoder observed about the fibre.
    let signal: FibreSignal

    /// The upstream bit-pattern value that produced this fibre.
    let upstreamValue: UInt64
}

// MARK: - Phase Tracker

/// Identifies a reduction phase for per-phase outcome tracking.
public enum ReducerPhaseIdentifier: Hashable, Sendable {
    case baseDescent
    case fibreDescent
    case exploration
}

/// Attributes property invocations and acceptances to the outermost active reduction phase.
///
/// Stack-based: each phase method pushes on entry and pops on exit. When relax-round (Phase 4) calls `runBaseDescent` and `runFibreDescent` internally, the stack is `[.relaxRound, .baseDescent]` — attributions go to `.relaxRound` (the outermost phase that initiated the work). Invocations from rolled-back phases are kept (they consumed real budget); acceptances from rolled-back phases are reverted (the improvements were undone).
struct PhaseTracker {
    typealias Phase = ReducerPhaseIdentifier

    struct PhaseCounts {
        var propertyInvocations: Int = 0
        var acceptances: Int = 0
        var structuralAcceptances: Int = 0
    }

    private var stack: [Phase] = []
    private(set) var counts: [Phase: PhaseCounts] = [:]

    mutating func push(_ phase: Phase) {
        stack.append(phase)
    }

    mutating func pop() {
        guard stack.isEmpty == false else { return }
        stack.removeLast()
    }

    mutating func recordInvocation() {
        guard let phase = stack.first else { return }
        counts[phase, default: PhaseCounts()].propertyInvocations += 1
    }

    mutating func recordAcceptance(structural: Bool) {
        guard let phase = stack.first else { return }
        counts[phase, default: PhaseCounts()].acceptances += 1
        if structural {
            counts[phase, default: PhaseCounts()].structuralAcceptances += 1
        }
    }

    mutating func revertAcceptance(structural: Bool) {
        guard let phase = stack.first else { return }
        counts[phase, default: PhaseCounts()].acceptances -= 1
        if structural {
            counts[phase, default: PhaseCounts()].structuralAcceptances -= 1
        }
    }

    /// Restores acceptance counts for a phase to a prior checkpoint.
    mutating func restoreAcceptances(
        for phase: Phase,
        acceptances: Int,
        structuralAcceptances: Int
    ) {
        counts[phase, default: PhaseCounts()].acceptances = acceptances
        counts[phase, default: PhaseCounts()].structuralAcceptances = structuralAcceptances
    }

    /// Builds a ``PhaseOutcome`` for the given phase with its accumulated counts.
    func outcome(for phase: Phase, budgetAllocated: Int) -> PhaseOutcome {
        let phaseCounts = counts[phase] ?? PhaseCounts()
        return PhaseOutcome(
            propertyInvocations: phaseCounts.propertyInvocations,
            acceptances: phaseCounts.acceptances,
            structuralAcceptances: phaseCounts.structuralAcceptances,
            budgetAllocated: budgetAllocated
        )
    }

    mutating func reset() {
        stack = []
        counts = [:]
    }
}

// MARK: - Cycle Outcome

/// Captures per-phase outcome data for one reduction cycle.
///
/// Collected by the scheduler at the end of each cycle. Phase-level summaries drive budget and ordering decisions in the adaptive strategy. Fine-grained decisions (per-coordinate, per-edge) bypass this struct and read the convergence cache and edge observations directly.
public struct CycleOutcome: Sendable {
    public var baseDescent: PhaseDisposition
    public var fibreDescent: PhaseDisposition
    public var exploration: PhaseDisposition

    public var zeroingDependencyCount: Int
    public var monotoneConvergenceCount: Int

    public var exhaustedCleanEdges: Int
    public var exhaustedWithFailureEdges: Int
    public var totalEdges: Int

    public var improved: Bool
    public var cycle: Int
}

/// Distinguishes "the scheduler chose not to run this phase" from "the scheduler ran this phase and it produced nothing."
public enum PhaseDisposition: Sendable {
    case ran(PhaseOutcome)
    case gated(reason: GateReason)
}

/// Reason a phase was not dispatched.
public enum GateReason: Sendable {
    case allCoordinatesConverged
    case noProgress
    case allEdgesClean
}

/// Per-phase outcome from a single cycle.
public struct PhaseOutcome: Sendable {
    /// Property invocations consumed by this phase (including rolled-back invocations).
    public var propertyInvocations: Int

    /// Net acceptances that survived rollback.
    public var acceptances: Int

    /// Of the net acceptances, how many were structural (changed sequence length or bind structure).
    public var structuralAcceptances: Int

    /// Budget allocated to this phase by the scheduler.
    public var budgetAllocated: Int

    /// Fraction of allocated budget consumed.
    public var utilization: Double {
        budgetAllocated > 0 ? Double(propertyInvocations) / Double(budgetAllocated) : 0
    }
}

// MARK: - Convergence Instrumentation

/// Measurement-only instrumentation for encoder convergence events.
///
/// Tracks per-coordinate convergence stability and cycle count across the reduction pipeline. Populated by encoders via ``AdaptiveEncoder/convergenceRecords`` and harvested by ``ReductionState/runAdaptive(_:decoder:targets:structureChanged:budget:fingerprintGuard:)``. Only allocated when debug logging is enabled.
struct ConvergenceInstrumentation {
    struct ConvergenceRecord {
        let coordinateIndex: Int
        let convergedValue: UInt64
        let cycle: Int
    }

    var records: [ConvergenceRecord] = []

    /// Total convergence events recorded by encoders (convergences and successful reductions).
    var totalEncoderConvergences = 0
}
