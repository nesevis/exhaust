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
