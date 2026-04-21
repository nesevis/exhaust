//
//  Sequence+FirstNonNil.swift
//  Exhaust
//
//  Created by Chris Kolbu on 28/2/2026.
//

// Adapted from Swift algorithms: https://swiftpackageindex.com/apple/swift-algorithms/1.2.1/documentation/algorithms
package extension Sequence {
    /// Returns the first sequence element where the transform provides a non-nil return value.
    func firstNonNil<Output>(
        _ transform: (Element) throws -> Output?
    ) rethrows -> Output? {
        for value in self {
            if let value = try transform(value) {
                return value
            }
        }
        return nil
    }
}
