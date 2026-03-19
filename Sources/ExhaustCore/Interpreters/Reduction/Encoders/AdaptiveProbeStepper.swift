//
//  AdaptiveProbeStepper.swift
//  Exhaust
//
//  Created by Chris Kolbu on 14/3/2026.
//

/// Step-by-step driver for ``AdaptiveProbe.findInteger``, for use in ``AdaptiveEncoder`` conformances.
///
/// Produces probes in the same order as ``findInteger`` (linear 1...4, exponential doubling, binary search), but yields one probe at a time so the scheduler can provide acceptance feedback between probes.
struct FindIntegerStepper {
    // MARK: - State

    private enum Phase {
        case linear(next: Int)
        case exponential(low: Int, high: Int)
        case binary(low: Int, high: Int)
        case done
    }

    private var phase = Phase.done
    private var lastProbe = 0

    /// The largest probe value that was accepted. Valid after convergence.
    private(set) var bestAccepted = 0

    // MARK: - API

    /// Resets the stepper and returns the first probe (always 1).
    mutating func start() -> Int {
        phase = .linear(next: 1)
        bestAccepted = 0
        lastProbe = 1
        return 1
    }

    /// Advances the stepper given feedback on the previous probe.
    ///
    /// - Returns: The next probe value, or `nil` when converged.
    mutating func advance(lastAccepted: Bool) -> Int? {
        if lastAccepted {
            bestAccepted = lastProbe
        }

        switch phase {
        case let .linear(next):
            if lastAccepted {
                if next < 4 {
                    let probe = next + 1
                    phase = .linear(next: probe)
                    lastProbe = probe
                    return probe
                }
                // Transition to exponential. low = 4 (last accepted), high = 8.
                phase = .exponential(low: 4, high: 8)
                lastProbe = 8
                return 8
            }
            // Rejection during linear scan — converged at bestAccepted.
            phase = .done
            return nil

        case let .exponential(_, high):
            if lastAccepted {
                let newLow = high
                let (doubled, overflow) = high.multipliedReportingOverflow(by: 2)
                if overflow {
                    // Can't go higher — converged.
                    phase = .done
                    return nil
                }
                phase = .exponential(low: newLow, high: doubled)
                lastProbe = doubled
                return doubled
            }
            // Rejection — answer is in (low, high). Binary search.
            let low = bestAccepted
            if low + 1 >= high {
                phase = .done
                return nil
            }
            let mid = low + (high - low) / 2
            phase = .binary(low: low, high: high)
            lastProbe = mid
            return mid

        case let .binary(low, high):
            let newLow = lastAccepted ? lastProbe : low
            let newHigh = lastAccepted ? high : lastProbe
            if newLow + 1 >= newHigh {
                phase = .done
                return nil
            }
            let mid = newLow + (newHigh - newLow) / 2
            phase = .binary(low: newLow, high: newHigh)
            lastProbe = mid
            return mid

        case .done:
            return nil
        }
    }
}

/// Step-by-step driver for ``AdaptiveProbe.binarySearchWithGuess``, for use in ``AdaptiveEncoder`` conformances.
///
/// Produces probes in the same order as ``binarySearchWithGuess`` — starts at the guess, then uses ``findInteger``-style expansion/contraction based on whether the guess was on the "good" or "bad" side.
/// Searches for the **smallest** accepted value via binary search.
///
/// On acceptance, narrows the upper bound (`hi = probe`). On rejection, narrows the lower bound (`lo = probe + 1`). Converges to the smallest value that is accepted. Used by ``BinarySearchToSemanticSimplestEncoder`` and ``BinarySearchToRangeMinimumEncoder`` where the goal is to find the simplest (smallest bit pattern) value that still fails the property.
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
