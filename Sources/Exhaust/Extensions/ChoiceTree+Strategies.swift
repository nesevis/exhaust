//
//  ChoiceTree+Strategies.swift
//  Exhaust
//
//  Created by Chris Kolbu on 22/7/2025.
//

import Algorithms

extension ChoiceTree {
    var children: [ChoiceTree] {
        switch self {
        case let .sequence(_, elements, _):
            elements
        case let .branch(_, _, choice):
            [choice]
        case let .group(array):
            array
        default:
            fatalError("\(#function) should not be accessed directly by \(self)")
        }
    }
    
    var length: UInt64 {
        if case .sequence(let length, _, _) = self {
            return length
        }
        fatalError("\(#function) should not be accessed directly by \(self)")
    }
    
    var effectiveRange: Double? {
        switch self {
        case .choice(let choiceValue, let choiceMetadata):
            let range = choiceMetadata.validRanges[0]
            switch choiceValue {
            case .unsigned:
                // Is this necessary?
                return Double(UInt64(bitPattern64: range.upperBound - range.lowerBound))
            case .signed:
                return Double(UInt64(bitPattern64: range.upperBound - range.lowerBound))
            case .floating:
                let lower = Double(bitPattern64: range.lowerBound)
                let upper = Double(bitPattern64: range.upperBound)
                let range = upper - lower
                if range.isFinite == false {
                    return Double.greatestFiniteMagnitude
                }
                return upper - lower
            case .character(let character):
                guard let range = choiceMetadata.validRanges.first(where: { $0.contains(character.bitPattern64) }) else {
                    // FIXME: This used to throw but now fails because character is a pick
                    return nil
                }
                return Double(UInt32(bitPattern64: range.upperBound - range.lowerBound))
            }
        case .sequence(_, _, let choiceMetadata):
            let range = choiceMetadata.validRanges[0]
            return Double(UInt64(bitPattern64: range.upperBound - range.lowerBound))
        default:
            return nil
        }
    }
}

extension ChoiceValue {
    #warning("The range casting here is fraught")
    func combinatoryComplexity(for range: ClosedRange<UInt64>) -> Double {
        switch self {
        case .unsigned:
            return Double(range.upperBound - range.lowerBound)
        case .signed:
            let range = range.cast(type: Int64.self)
            return Double(abs(range.upperBound - range.lowerBound))
        case .floating:
            let range = range.cast(type: Double.self)
            return abs(range.upperBound - range.lowerBound)
        case .character:
            return Double(range.upperBound - range.lowerBound)
        }
    }
}
