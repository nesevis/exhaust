//
//  Choice.swift
//  Exhaust
//
//  Created by Chris Kolbu on 20/7/2025.
//

enum ChoiceValue: Comparable, Hashable, Equatable {
    case uint(UInt64)
    case character(Character)

    // Make shrinkable?
    init(_ value: any BitPatternConvertible) {
        if let character = value as? Character {
            self = .character(character)
        } else {
            self = .uint(value.bitPattern64)
        }
    }

    var convertible: any BitPatternConvertible {
        switch self {
        case .uint(let uInt64):
            return uInt64
        case .character(let character):
            return character
        }
    }
}
