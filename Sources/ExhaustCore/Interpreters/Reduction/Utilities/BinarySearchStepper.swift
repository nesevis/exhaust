//
//  BinarySearchStepper.swift
//  Exhaust
//
//  Created by Chris Kolbu on 12/4/2026.
//

/// Step-by-step driver for ``AdaptiveProbe.binarySearchWithGuess``, for use in ``ComposableEncoder`` conformances.
///
/// Produces probes in the same order as ``binarySearchWithGuess`` — starts at the guess, then uses ``findInteger``-style expansion/contraction based on whether the guess was on the "good" or "bad" side. Searches for the smallest accepted value via binary search.
///
/// On acceptance, narrows the upper bound (`hi = probe`). On rejection, narrows the lower bound (`lo = probe + 1`). Converges to the smallest value that is accepted.
struct BinarySearchStepper {
    // MARK: - State

    private var lo: UInt64
    private var hi: UInt64
    private var lastProbe: UInt64 = 0
    private var converged = false

    /// The best accepted value (smallest for a toward-zero search).
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

    /// Returns the first probe value (midpoint), or `nil` if already converged.
    mutating func start() -> UInt64? {
        guard lo < hi else {
            converged = true
            return nil
        }
        let mid = lo + (hi - lo) / 2
        lastProbe = mid
        return mid
    }

    /// Advances the search given feedback on the previous probe.
    mutating func advance(lastAccepted: Bool) -> UInt64? {
        guard converged == false else { return nil }

        if lastAccepted {
            bestAccepted = lastProbe
            hi = lastProbe
        } else {
            lo = lastProbe + 1
        }

        guard lo < hi else {
            converged = true
            return nil
        }

        let mid = lo + (hi - lo) / 2
        lastProbe = mid
        return mid
    }
}
