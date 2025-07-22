//
//  ChoiceTree+Strategies.swift
//  Exhaust
//
//  Created by Chris Kolbu on 22/7/2025.
//

extension ChoiceTree {
    var children: [ChoiceTree] {
        switch self {
        case let .sequence(_, elements, _):
            elements
        case let .branch(_, children):
            children
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

    /// Represents ShrinkingStrategies.fundamentals
    var fundamentalValues: [ChoiceTree] {
        switch self {
        case let .choice(value, metadata):
            return value.fundamentalValues
                // TODO: Optimise, though these are O(1) lookups
                .filter { value in metadata.validRanges.contains(where: { $0.contains(value.convertible.bitPattern64) })}
                .map { .choice($0, metadata) }
        case let .sequence(length, elements, meta):
            guard length > 0 else {
                return []
            }
            return [
                // No elements
                .sequence(length: 0, elements: [], meta),
                // The first element
                .sequence(length: 1, elements: Array(elements.prefix(1)), meta),
                // The last element
                .sequence(length: 1, elements: Array(elements.suffix(1)), meta)
            ].filter { sequence in meta.validRanges.contains(where: { $0.contains(sequence.length) })}
        default:
            fatalError("\(#function) should not be called directly for \(self)!")
        }
    }
    
    /// Represents ShrinkingStrategies.boundaries
    var boundaries: [ChoiceTree] {
        switch self {
        case let .choice(value, metadata):
            return value.boundaries
                // TODO: Optimise, though these are O(1) lookups
                .filter { value in metadata.validRanges.contains(where: { $0.contains(value.convertible.bitPattern64) })}
                .map { .choice($0, metadata) }
        case let .sequence(length, elements, meta):
            guard length > 1 else {
                return []
            }
            return [
                .sequence(length: length - 1, elements: Array(elements.dropFirst()), meta),
                .sequence(length: length - 1, elements: Array(elements.dropLast()), meta)
            ]
        default:
            fatalError("\(#function) should not be called directly for \(self)!")
        }
    }
    
    var binary: [ChoiceTree] {
        switch self {
        case let .choice(value, metadata):
            return value.binary(for: metadata.validRanges)
                .filter { value in metadata.validRanges.contains(where: { $0.contains(value.convertible.bitPattern64) })}
                .map { .choice($0, metadata) }
        case let .sequence(length, elements, meta):
            guard length > 1 else {
                return []
            }
            // Split the array in ~half
            let halvingPoint = length / 2
            return [
                .sequence(length: halvingPoint, elements: Array(elements.prefix(Int(halvingPoint))), meta),
                .sequence(length: length - halvingPoint, elements: Array(elements.dropFirst(Int(halvingPoint))), meta)
            ]
            // TODO: The filter check above can be done on the lengths themselves
            
        default:
            fatalError("\(#function) should not be called directly for \(self)!")
        }
    }
    
    func resetStrategies() -> Self {
        switch self {
        case let .choice(value, meta):
            let strategies: ShrinkingStrategies = switch value {
            case .unsigned:
                .unsignedIntegers
            case .signed:
                .signedIntegers
            case .floating:
                .floatingPoints
            case .character:
                .unsignedIntegers
            }
            let newMeta = ChoiceMetadata(validRanges: meta.validRanges, strategies: strategies)
            return .choice(value, newMeta)
        case .just:
            return self
        case let .sequence(length, elements, meta):
            let newMeta = ChoiceMetadata(validRanges: meta.validRanges, strategies: .sequences)
            return .sequence(length: length, elements: elements.map { $0.resetStrategies() }, newMeta)
        case let .branch(label, children):
            return .branch(label: label, children: children.map { $0.resetStrategies() })
        case let .group(array):
            return .group(array.map { $0.resetStrategies() })
        }
    }
}
