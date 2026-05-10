//
//  FixedWidthInteger+CeilLog2.swift
//  Exhaust
//

extension FixedWidthInteger {
    /// The number of bits needed to represent this value, rounding up. Returns 1 for values of 0 or 1.
    ///
    /// Used by the scheduler to estimate probe counts from domain sizes and distances: a value that fits in *k* bits needs at most *k* binary search steps to reach.
    var ceilLog2: Int {
        guard self > 1 else { return 1 }
        return Self.bitWidth - (self - 1).leadingZeroBitCount
    }
}
