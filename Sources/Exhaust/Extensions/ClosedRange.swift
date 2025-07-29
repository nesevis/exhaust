//
//  ClosedRange.swift
//  Exhaust
//
//  Created by Chris Kolbu on 29/7/2025.
//

extension ClosedRange where Bound == UInt64 {
    func cast<ToType: BitPatternConvertible & Comparable>(type: ToType.Type = ToType.self) -> ClosedRange<ToType> {
        ToType(bitPattern64: lowerBound)...ToType(bitPattern64: upperBound)
    }
}
