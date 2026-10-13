//
//  InterpolationSearchStepper.swift
//  Exhaust
//
//  Created by Chris Kolbu on 12/4/2026.
//

/// Step-by-step driver for interpolation search with binary search fallback over a `UInt64` range.
///
/// In `.findSmallest` mode, probes bias toward `lo` under the prior that the boundary is near the reduction target. In `.findLargest` mode, probes bias toward `hi`. The divisor `K` starts at the initial divisor (16 by default) and halves on rejection (flooring at 2, which is pure binary search). On acceptance, `K` resets to the initial divisor for the narrowed interval.
///
/// Transitions to pure binary search when the interval narrows below the binary threshold (``binaryThreshold`` by default).
struct InterpolationSearchStepper {
    // MARK: - State

    private let direction: SearchDirection
    private var lo: UInt64
    private var hi: UInt64
    private var lastProbe: UInt64 = 0
    private var converged = false
    private var divisor: UInt64
    private let interpolationDivisor: UInt64
    private let binarySearchThreshold: UInt64

    /// The default threshold below which the stepper switches from interpolation to binary search.
    static let binaryThreshold: UInt64 = 1024

    /// The default initial divisor for the interpolation phase.
    static let initialDivisor: UInt64 = 16

    /// The best accepted value found so far.
    private(set) var bestAccepted: UInt64

    // MARK: - Init

    /// - Parameters:
    ///   - lo: The lower bound of the search range.
    ///   - hi: The upper bound of the search range.
    ///   - direction: Whether to find the smallest or largest accepted value.
    ///   - binaryThreshold: The interval size below which the stepper switches to binary search.
    ///   - initialDivisor: The interpolation divisor the search starts with and returns to after each acceptance.
    init(
        lo: UInt64,
        hi: UInt64,
        direction: SearchDirection = .findSmallest,
        binaryThreshold: UInt64 = Self.binaryThreshold,
        initialDivisor: UInt64 = Self.initialDivisor
    ) {
        self.direction = direction
        binarySearchThreshold = binaryThreshold
        interpolationDivisor = initialDivisor
        divisor = initialDivisor
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
                    divisor = interpolationDivisor
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
                    divisor = interpolationDivisor
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
        if range < binarySearchThreshold {
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
