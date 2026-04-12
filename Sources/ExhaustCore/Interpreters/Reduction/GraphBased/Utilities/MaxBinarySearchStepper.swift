//
//  MaxBinarySearchStepper.swift
//  Exhaust
//
//  Created by Chris Kolbu on 12/4/2026.
//

/// Searches for the **largest** accepted value via binary search.
///
/// On acceptance, narrows the lower bound (`lo = probe + 1`). On rejection, narrows the upper bound (`hi = probe`). Converges to the largest value that is accepted. Used by ``RedistributeByTandemReductionEncoder`` where the goal is to find the largest shared delta that still fails the property — maximizing the reduction.
struct MaxBinarySearchStepper {
    // MARK: - State

    private var lo: UInt64
    private var hi: UInt64
    private var lastProbe: UInt64 = 0
    private var converged = false

    /// The largest accepted value found so far.
    private(set) var bestAccepted: UInt64

    // MARK: - Init

    /// - Parameters:
    ///   - lo: The minimum delta to try (typically 0).
    ///   - hi: The maximum delta to try (typically the full distance to target).
    init(lo: UInt64, hi: UInt64) {
        self.lo = lo
        self.hi = hi
        bestAccepted = lo
    }

    /// Returns the first probe value (midpoint), or `nil` if already converged.
    mutating func start() -> UInt64? {
        guard lo < hi else {
            converged = true
            return nil
        }
        let mid = lo + (hi - lo + 1) / 2 // bias high
        lastProbe = mid
        return mid
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
        } else {
            guard lastProbe > lo else {
                converged = true
                return nil
            }
            hi = lastProbe - 1
        }

        guard lo <= hi else {
            converged = true
            return nil
        }

        let mid = lo + (hi - lo + 1) / 2 // bias high
        lastProbe = mid
        return mid
    }
}
