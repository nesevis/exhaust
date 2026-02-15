//
//  ChoiceValue+Reductions.swift
//  Exhaust
//
//  Created by Chris Kolbu on 10/2/2026.
//

extension ChoiceValue {
    
    // Used when comparing failures. The problem is that we don't know where the boundaries lay outside of which the property is true. So should this be run after the successful `refineEndOfRange` tests to help hone in on the least absolutely complex value within the range?
    func refineRange(against other: ChoiceValue, direction: ShrinkingDirection) -> ClosedRange<UInt64>? {
        // If increasing, the range should be lhs..<rhs, if decreasing rhs...lhs
        let minVal = min(self.bitPattern64, other.bitPattern64)
        let maxVal = max(self.bitPattern64, other.bitPattern64)
        switch direction {
        case .towardsHigherBound:
            // Range (..<) can't have the two values be equal to each other
            return minVal == maxVal ? minVal...maxVal : ClosedRange(minVal..<maxVal)
        case .towardsLowerBound:
            return minVal...maxVal
        }
    }
    
    // Used when we know the other value represents a refinement of one end of the range
    // E.g we are comparing `self`, a failure, against `other`, a successful value
    func refineOneEndOfRange(against other: ChoiceValue, range: ClosedRange<UInt64>) -> ClosedRange<UInt64>? {
        guard range.contains(other.bitPattern64) else {
            return nil
        }
        if self < other {
            // This represents a refinement of the top range to the value of other - 1
            switch (self, other) {
            case let (.unsigned(lhs, _), .unsigned(rhs, _)):
                return range.lowerBound...min(range.upperBound, rhs)
            case let (.signed(_, lhs, _), .signed(_, rhs, _)):
                return range.lowerBound...min(range.upperBound, rhs)
            case let (.floating(lhsV, lhs, _), .floating(rhsV, rhs, _)):
                return range.lowerBound...min(range.upperBound, rhs)
            case let (.character(lhs), .character(rhs)):
                return range.lowerBound.bitPattern64...min(range.upperBound, rhs.bitPattern64)
            default:
                fatalError("Can't compare different values")
            }
        } else {
            // self (fail) is larger or equal to other (pass)
            // This represents a refinement of the bottom of the range to the value of the other + 1
            // Does it matter if the range is wholly negative?
            switch (self, other) {
            case let (.unsigned(lhs, _), .unsigned(rhs, _)):
                return max(range.lowerBound, rhs + 1)...range.upperBound
            case let (.signed(lhs, _, _), .signed(_, rhs, _)):
                return max(range.lowerBound, rhs + 1)...range.upperBound
            case let (.floating(lhs, _, _), .floating(_, rhs, _)):
                return max(range.lowerBound, rhs + 1)...range.upperBound
            case let (.character(lhs), .character(rhs)):
                return max(range.lowerBound, rhs.bitPattern64 + 1)...range.upperBound
            default:
                fatalError("Can't compare different values")
            }
        }
    }
}
