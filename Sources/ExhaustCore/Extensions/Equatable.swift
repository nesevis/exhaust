//
//  Equatable.swift
//  Exhaust
//
//  Created by Chris Kolbu on 25/7/2025.
//

/// https://nilcoalescing.com/blog/CheckIfTwoValuesOfTypeAnyAreEqual/
package extension Equatable {
    /// Performs type-erased equality by attempting a two-phase cast (direct, then reverse) to handle cases where existential wrapping erases the concrete type on one side but not the other.
    func isEqual(_ other: any Equatable) -> Bool {
        guard let other = other as? Self else {
            return other.isExactlyEqual(self)
        }
        return self == other
    }

    private func isExactlyEqual(_ other: any Equatable) -> Bool {
        guard let other = other as? Self else {
            return false
        }
        return self == other
    }

    /// Returns false for non-``Equatable`` values, providing a safe fallback for heterogeneous comparison without requiring the caller to check conformance.
    func isEqualToAny(_ other: Any) -> Bool {
        guard let other = other as? any Equatable else {
            return false
        }
        return isEqual(other)
    }
}
