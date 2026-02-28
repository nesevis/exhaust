//
//  ClosedRange.swift
//  Exhaust
//
//  Created by Chris Kolbu on 29/7/2025.
//

@_spi(ExhaustInternal) public extension ClosedRange where Bound: Strideable {
    var asRange: Range<Bound> {
        lowerBound ..< upperBound.advanced(by: 1)
    }
}
