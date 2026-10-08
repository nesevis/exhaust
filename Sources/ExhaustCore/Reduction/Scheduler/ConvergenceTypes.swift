//
//  ConvergenceTypes.swift
//  Exhaust
//
//  Created by Chris Kolbu on 25/3/2026.
//

/// Stores the convergence bound and observation from a prior encoder pass.
///
/// Carries warm-start data (`bound`), the encoder's observation (`signal`), the configuration that produced it (`configuration`), and the cycle number for staleness detection. Stored in ``ChoiceGraph/convergenceStore`` keyed by node ID and harvested by the scheduler after each probe loop.
///
/// When a leaf's convergence record is overwritten by a later cycle, ``priorBound`` captures the previous floor. A non-nil value where `priorBound != bound` indicates floor motion: the leaf's convergence point shifted, which is the observable signal for inter-coordinate coupling.
package struct ConvergedOrigin: Sendable {
    /// The bit-pattern value at which the search converged. Warm-start data.
    package let bound: UInt64

    /// The bound from the previous convergence record at this leaf, if any. Non-nil when this record overwrites a prior entry in the convergence store. A difference between `priorBound` and `bound` indicates that a partner coordinate's movement shifted this leaf's convergence floor.
    package let priorBound: UInt64?

    /// Describes what the encoder observed at convergence. Factory decision data.
    package let signal: ConvergenceSignal

    /// Identifies which encoder configuration produced this entry. Staleness discriminant.
    package let configuration: EncoderConfiguration

    /// The cycle in which this observation was recorded. Staleness detection.
    package let cycle: Int

    /// The graph rebuild generation at which this record was written to the convergence store. Stamped by ``ChoiceGraph/recordConvergence(byNodeID:rebuildGeneration:)``, not by encoders. Used to distinguish structural floor motion (rebuild between old and new record) from value floor motion (same generation, floor shifted by partner movement).
    package let rebuildGeneration: Int

    /// Creates a convergence record with the given warm-start bound, signal, configuration, and cycle.
    package init(
        bound: UInt64,
        priorBound: UInt64? = nil,
        signal: ConvergenceSignal,
        configuration: EncoderConfiguration,
        cycle: Int,
        rebuildGeneration: Int = 0
    ) {
        self.bound = bound
        self.priorBound = priorBound
        self.signal = signal
        self.configuration = configuration
        self.cycle = cycle
        self.rebuildGeneration = rebuildGeneration
    }
}

/// Records what an encoder observed when it terminated, reported to the factory for cross-cycle decisions.
///
/// Each encoder produces a signal at convergence. The factory pattern-matches on the signal to select the recovery encoder for the next cycle. Signals are stored in ``ConvergedOrigin`` alongside the warm-start bound.
package enum ConvergenceSignal: Hashable, Sendable {
    /// Binary search converged normally. Monotonicity held throughout.
    case monotoneConvergence

    /// Binary search: the property passed at a value where the monotonicity assumption predicted failure. The failure surface has a gap — bounded scan below the convergence point may find a lower floor.
    case nonMonotoneGap(remainingRange: Int)

    /// Zero-value: batch zeroing failed but at least one individual zeroing succeeded. The coordinate has dependencies on other coordinates.
    case zeroingDependency

    /// Linear scan completed. The factory reverts to binary search on the next cycle.
    case scanComplete(foundLowerFloor: Bool)
}

/// Identifies the encoder configuration that produced a convergence record.
///
/// The factory uses this to reject cache entries from a different configuration so that warm-start data from one encoder does not pollute another's search.
package enum EncoderConfiguration: Hashable, Sendable {
    case binarySearchSemanticSimplest
    case linearScan
}
