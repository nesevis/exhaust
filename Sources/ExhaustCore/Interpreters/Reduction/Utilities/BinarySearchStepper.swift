//
//  BinarySearchStepper.swift
//  Exhaust
//
//  Created by Chris Kolbu on 12/4/2026.
//

/// Direction for binary and interpolation search steppers.
enum SearchDirection {
    /// Searches for the smallest accepted value. Probes bias toward `lo`.
    case findSmallest
    /// Searches for the largest accepted value. Probes bias toward `hi`.
    case findLargest
}

/// Step-by-step driver for binary search over a `UInt64` range.
///
/// In `.findSmallest` mode, searches for the smallest accepted value: acceptance narrows the upper bound, rejection narrows the lower bound. In `.findLargest` mode, searches for the largest accepted value with the opposite narrowing.
struct BinarySearchStepper {
    // MARK: - State

    private let direction: SearchDirection
    private var lo: UInt64
    private var hi: UInt64
    private var lastProbe: UInt64 = 0
    private var converged = false

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
        lastProbe = midpoint()
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
            } else {
                lo = lastProbe + 1
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
        }

        lastProbe = midpoint()
        return lastProbe
    }

    // MARK: - Probe Point

    private func midpoint() -> UInt64 {
        let range = hi - lo
        switch direction {
        case .findSmallest:
            return lo + range / 2
        case .findLargest:
            return lo + (range >> 1) + (range & 1)
        }
    }
}
