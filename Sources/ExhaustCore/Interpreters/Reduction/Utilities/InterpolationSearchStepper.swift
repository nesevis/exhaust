//
//  InterpolationSearchStepper.swift
//  Exhaust
//
//  Created by Chris Kolbu on 12/4/2026.
//

/// Searches for the **smallest** accepted value using interpolation search with binary search fallback.
///
/// Probes near `lo` (the reduction target) during the interpolation phase, under the prior that most values can be reduced to or near the target. The divisor `K` starts at 4 (probing at 25% of the range from `lo`) and halves on rejection to K=2 (binary search). On acceptance, `K` resets to 4 for the narrowed interval.
///
/// Transitions to pure binary search when the interval shrinks below 1024 values, where the interpolation estimate provides negligible advantage over midpoint bisection.
///
/// Uses `UInt64.multipliedFullWidth(by:)` and `dividingFullWidth(_:)` for the probe-point calculation to avoid overflow on large ranges.
struct InterpolationSearchStepper {
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

    /// The best accepted value (smallest for a toward-target search).
    private(set) var bestAccepted: UInt64

    // MARK: - Init

    /// - Parameters:
    ///   - lo: The target value (semantic simplest / reduction target).
    ///   - hi: The current value.
    init(lo: UInt64, hi: UInt64) {
        self.lo = lo
        self.hi = hi
        bestAccepted = hi
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
            hi = lastProbe
            // Reset divisor on acceptance — the "boundary near lo" prior is confirmed by the acceptance.
            divisor = Self.initialDivisor
        } else {
            lo = lastProbe + 1
            // Halve divisor on rejection, flooring at 2 (binary search).
            if divisor > 2 {
                divisor /= 2
            }
        }

        guard lo < hi else {
            converged = true
            return nil
        }

        lastProbe = probePoint()
        return lastProbe
    }

    // MARK: - Probe Point

    /// Computes the next probe point based on the current phase.
    ///
    /// In interpolation phase (`hi - lo >= binaryThreshold`), probes at `lo + range / divisor`. In binary phase, probes at the midpoint.
    private func probePoint() -> UInt64 {
        let range = hi - lo
        if range < Self.binaryThreshold {
            // Binary phase: midpoint.
            return lo + range / 2
        }
        // Interpolation phase: biased toward lo.
        // Use full-width arithmetic to avoid overflow:
        //   probe = lo + range / divisor For power-of-two divisors this is just a shift, but dividingFullWidth keeps the door open for non-power-of-two K.
        let step = range / divisor
        // Guard against step == 0 (divisor > range, shouldn't happen given the binaryThreshold gate, but be safe).
        if step == 0 {
            return lo + range / 2
        }
        return lo + step
    }
}
