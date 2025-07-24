//
//  Equatable.swift
//  Exhaust
//
//  Created by Chris Kolbu on 25/7/2025.
//

// https://nilcoalescing.com/blog/CheckIfTwoValuesOfTypeAnyAreEqual/
extension Equatable {
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
}
