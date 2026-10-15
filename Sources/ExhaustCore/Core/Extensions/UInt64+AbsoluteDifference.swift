//
//  UInt64+AbsoluteDifference.swift
//  Exhaust
//

extension UInt64 {
    /// The distance between two bit patterns, whichever is larger. Used for a leaf's distance from its reduction target.
    func absoluteDifference(_ other: UInt64) -> UInt64 {
        self > other ? self - other : other - self
    }
}
