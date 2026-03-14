/// Step-by-step driver for ``AdaptiveProbe.findInteger``, for use in ``AdaptiveEncoder`` conformances.
///
/// Produces probes in the same order as `findInteger` (linear 1...4, exponential doubling, binary search), but yields one probe at a time so the scheduler can provide acceptance feedback between probes.
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
        case .linear(let next):
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

        case .exponential(_, let high):
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

        case .binary(let low, let high):
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
/// Produces probes in the same order as `binarySearchWithGuess` — starts at the guess, then uses `findInteger`-style expansion/contraction based on whether the guess was on the "good" or "bad" side.
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
        self.bestAccepted = hi
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
