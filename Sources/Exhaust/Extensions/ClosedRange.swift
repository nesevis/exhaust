//
//  ClosedRange.swift
//  Exhaust
//
//  Created by Chris Kolbu on 29/7/2025.
//

extension ClosedRange where Bound == UInt64 {
    #warning("To be removed. Unless you specify the absolute correct type (Int8, Float, etc) this may be incorrect")
    func cast<ToType: BitPatternConvertible & Comparable>(type _: ToType.Type = ToType.self) -> ClosedRange<ToType> {
        ToType(bitPattern64: lowerBound) ... ToType(bitPattern64: upperBound)
    }
}

public extension ClosedRange where Bound: Strideable {
    var asRange: Range<Bound> {
        lowerBound ..< upperBound.advanced(by: 1)
    }
}
