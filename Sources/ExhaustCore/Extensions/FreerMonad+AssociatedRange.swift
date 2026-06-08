//
//  FreerMonad+AssociatedRange.swift
//  Exhaust
//
//  Created by Chris Kolbu on 9/6/2026.
//

extension FreerMonad where Operation == ReflectiveOperation {
    /// Exposes the explicit min/max constraint of a ``chooseBits`` leaf without interpreting the full generator. Used by ``EnumerableDomainProfile`` and coverage analysis to collect parameter ranges for covering-array construction. Returns nil for pure values, non-``chooseBits`` operations, or ranges derived from size scaling (which are not stable across runs).
    var associatedRange: ClosedRange<UInt64>? {
        switch self {
            case .pure:
                return nil
            case let .impure(op, _):
                guard case let .chooseBits(min, max, _, isRangeExplicit, _) = op,
                      isRangeExplicit
                else {
                    return nil
                }
                return min ... max
        }
    }
}
