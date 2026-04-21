//
//  MaxInterpolationSearchStepper.swift
//  Exhaust
//
//  Created by Chris Kolbu on 12/4/2026.
//

/// Searches for the **largest** accepted value using interpolation search with binary search fallback.
///
/// Probes near `hi` (the reduction target) during the interpolation phase, under the prior that most values can be reduced to or near the target. The divisor `K` starts at 4 (probing at 75% of the range from `lo`) and halves on rejection to K=2 (binary search). On acceptance, `K` resets to 4 for the narrowed interval.
///
/// Transitions to pure binary search when the interval shrinks below 1024 values.
struct MaxInterpolationSearchStepper {
    // MARK: - State

    private var lo: UInt64
    private var hi: UInt64
    private var lastProbe: UInt64 = 0
    private var converged = false
    private var divisor: UInt64 = 16

    /// The threshold below which the stepper switches from interpolation to binary search.
    static let binaryThreshold: UInt64 = 1024

    /// The initial divisor for the interpolation phase.
    private static let initialDivisor: UInt64 = 16

    /// The largest accepted value found so far.
    private(set) var bestAccepted: UInt64

    // MARK: - Init

    /// - Parameters:
    ///   - lo: The current value (minimum).
    ///   - hi: The target value (maximum to try).
    init(lo: UInt64, hi: UInt64) {
        self.lo = lo
        self.hi = hi
        bestAccepted = lo
    }

    /// Returns the first probe value, or `nil` if already converged.
    mutating func start() -> UInt64? {
        guard lo < hi else {
            converged = true
            return nil
        }
        lastProbe = probePoint()
        return lastProbe
    }

    /// Advances the search given feedback on the previous probe.
    mutating func advance(lastAccepted: Bool) -> UInt64? {
        guard converged == false else { return nil }

        if lastAccepted {
            bestAccepted = lastProbe
            let (next, overflow) = lastProbe.addingReportingOverflow(1)
            if overflow {
                converged = true
                return nil
            }
            lo = next
            // Reset divisor on acceptance — the "boundary near hi" prior is confirmed by the acceptance.
            divisor = Self.initialDivisor
        } else {
            guard lastProbe > lo else {
                converged = true
                return nil
            }
            hi = lastProbe - 1
            // Halve divisor on rejection, flooring at 2 (binary search).
            if divisor > 2 {
                divisor /= 2
            }
        }

        guard lo <= hi else {
            converged = true
            return nil
        }

        lastProbe = probePoint()
        return lastProbe
    }

    // MARK: - Probe Point

    /// Computes the next probe point based on the current phase.
    ///
    /// In interpolation phase (`hi - lo >= binaryThreshold`), probes at `hi - range / divisor` (biased toward `hi`). In binary phase, probes at the midpoint biased high.
    private func probePoint() -> UInt64 {
        let range = hi - lo
        if range < Self.binaryThreshold {
            // Binary phase: midpoint biased high.
            return lo + (range + 1) / 2
        }
        // Interpolation phase: biased toward hi.
        let step = range / divisor
        if step == 0 {
            return lo + (range + 1) / 2
        }
        return hi - step
    }
}
