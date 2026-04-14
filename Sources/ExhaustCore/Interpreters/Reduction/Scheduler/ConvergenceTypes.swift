//
//  ConvergenceTypes.swift
//  Exhaust
//
//  Created by Chris Kolbu on 25/3/2026.
//

/// Stores the convergence bound and observation from a prior encoder pass.
///
/// Carries warm-start data (`bound`), the encoder's observation (`signal`), the configuration that produced it (`configuration`), and the cycle number for staleness detection. Stored per graph node in ``ChoiceGraphNode/convergedOrigin`` and harvested by the scheduler after each probe loop.
package struct ConvergedOrigin: Sendable {
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
