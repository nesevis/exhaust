//
//  InterpolationSearchStepper.swift
//  Exhaust
//
//  Created by Chris Kolbu on 12/4/2026.
//

/// Step-by-step driver for interpolation search with binary search fallback over a `UInt64` range.
///
/// In `.findSmallest` mode, probes bias toward `lo` under the prior that the boundary is near the reduction target. In `.findLargest` mode, probes bias toward `hi`. The divisor `K` starts at 16 and halves on rejection (flooring at 2, which is pure binary search). On acceptance, `K` resets to 16 for the narrowed interval.
///
/// Transitions to pure binary search when the interval shrinks below ``binaryThreshold`` values.
struct InterpolationSearchStepper {
    // MARK: - State

    private let direction: SearchDirection
    private var lo: UInt64
    private var hi: UInt64
    private var lastProbe: UInt64 = 0
    private var converged = false
    private var divisor: UInt64 = Self.initialDivisor

    /// The threshold below which the stepper switches from interpolation to binary search.
    static let binaryThreshold: UInt64 = 1024

    /// The initial divisor for the interpolation phase.
    private static let initialDivisor: UInt64 = 16

    /// The best accepted value found so far.
    private(set) var bestAccepted: UInt64

    // MARK: - Init

    /// - Parameters:
    ///   - lo: The lower bound of the search range.
    ///   - hi: The upper bound of the search range.
    ///   - direction: Whether to find the smallest or largest accepted value.
    init(lo: UInt64, hi: UInt64, direction: SearchDirection = .findSmallest) {
        self.direction = direction
        self.lo = lo
        self.hi = hi
        switch direction {
            case .findSmallest: bestAccepted = hi
            case .findLargest: bestAccepted = lo
        }
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

        switch direction {
            case .findSmallest:
                if lastAccepted {
                    bestAccepted = lastProbe
                    hi = lastProbe
                    divisor = Self.initialDivisor
                } else {
                    lo = lastProbe + 1
                    if divisor > 2 { divisor /= 2 }
                }
                guard lo < hi else {
                    converged = true
                    return nil
                }

            case .findLargest:
                if lastAccepted {
                    bestAccepted = lastProbe
                    let (next, overflow) = lastProbe.addingReportingOverflow(1)
                    if overflow {
                        converged = true
                        return nil
                    }
                    lo = next
                    divisor = Self.initialDivisor
                } else {
                    guard lastProbe > lo else {
                        converged = true
                        return nil
                    }
                    hi = lastProbe - 1
                    if divisor > 2 { divisor /= 2 }
                }
                guard lo <= hi else {
                    converged = true
                    return nil
                }
        }

        lastProbe = probePoint()
        return lastProbe
    }

    // MARK: - Probe Point

    private func probePoint() -> UInt64 {
        let range = hi - lo
        if range < Self.binaryThreshold {
            switch direction {
                case .findSmallest:
                    return lo + range / 2
                case .findLargest:
                    return lo + (range + 1) / 2
            }
        }
        let step = range / divisor
        if step == 0 {
            switch direction {
                case .findSmallest:
                    return lo + range / 2
                case .findLargest:
                    return lo + (range + 1) / 2
            }
        }
        switch direction {
            case .findSmallest:
                return lo + step
            case .findLargest:
                return hi - step
        }
    }
}
