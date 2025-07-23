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
//            let newMeta = ChoiceMetadata(validRanges: meta.validRanges, strategies: .sequences)
            return [
                // No elements
                .sequence(length: 0, elements: [], meta),
                // The first element
                .sequence(length: 1, elements: Array(elements.prefix(1)), meta).resetStrategies(),
                // The last element
                .sequence(length: 1, elements: Array(elements.suffix(1)), meta).resetStrategies()
            ]
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
//            let newMeta = ChoiceMetadata(validRanges: meta.validRanges, strategies: .sequences)
            return [
                .sequence(length: length - 1, elements: Array(elements.dropFirst()), meta).resetStrategies(),
                .sequence(length: length - 1, elements: Array(elements.dropLast()), meta).resetStrategies()
            ]
        default:
            fatalError("\(#function) should not be called directly for \(self)!")
        }
    }
    
    var binary: [ChoiceTree] {
        switch self {
        case let .choice(value, metadata):
            return value.binary(for: metadata.validRanges)
                .map { .choice($0, metadata) }
        case let .sequence(length, elements, meta):
            guard length > 1 else {
                return []
            }
            // Split the array in ~half
//            let newMeta = ChoiceMetadata(validRanges: meta.validRanges, strategies: .sequences)
            let halvingPoint = length / 2
            return [(halvingPoint, true), (length - halvingPoint, false)]
                .filter { pair in meta.isValidForRange(pair.0) }
                .map { length, prefix in
                    let subArray = prefix
                        ? Array(elements.prefix(Int(length)))
                        : Array(elements.suffix(Int(length)))
                    return .sequence(length: length, elements: subArray, meta).resetStrategies()
                }
        default:
            fatalError("\(#function) should not be called directly for \(self)!")
        }
    }
    
    var saturation: [ChoiceTree] {
        switch self {
        case let .choice(value, metadata):
            return value.saturation(for: metadata.validRanges)
                .map { .choice($0, metadata).resetStrategies() }
        case let .sequence(length, elements, meta):
            guard length > 1 else {
                return []
            }
            
            let chunks = elements.evenlyChunked(in: Int(length) / 10)
            
            return chunks
                .filter { meta.isValidForRange(UInt64($0.count)) }
                .map { chunk in
                    .sequence(length: UInt64(chunk.count), elements: Array(chunk), meta).resetStrategies()
                }
        default:
            fatalError("\(#function) should not be called directly for \(self)!")
        }
    }
    
    var ultraSaturation: [ChoiceTree] {
        switch self {
        case let .choice(value, metadata):
            return value.ultraSaturation(for: metadata.validRanges)
                .map { .choice($0, metadata).setStrategies([.ultraSaturation]) }
        case let .sequence(_, _, _):
            return self.boundaries.map { $0.setStrategies([.ultraSaturation])}
        default:
            fatalError("\(#function) should not be called directly for \(self)!")
        }
    }
    
    func setStrategies(_ strategies: [ShrinkingStrategy]) -> Self {
        switch self {
        case let .choice(value, meta):
            let newMeta = ChoiceMetadata(validRanges: meta.validRanges, strategies: strategies)
            return .choice(value, newMeta)
        case .just:
            return self
        case let .sequence(length, elements, meta):
            let newMeta = ChoiceMetadata(validRanges: meta.validRanges, strategies: ShrinkingStrategy.sequences)
            return .sequence(length: length, elements: elements.map { $0.setStrategies(strategies) }, newMeta)
        case let .branch(label, children):
            return .branch(label: label, children: children.map { $0.setStrategies(strategies) })
        case let .group(array):
            return .group(array.map { $0.setStrategies(strategies) })
        case let .important(element):
            return .important(element.setStrategies(strategies))
        }
    }
    
    func resetStrategies() -> Self {
        switch self {
        case let .choice(value, meta):
            let strategies: [ShrinkingStrategy] = switch value {
            case .unsigned:
                UInt64.strategies
            case .signed:
                Int64.strategies
            case .floating:
                Double.strategies
            case .character:
                Character.strategies
            }
            return self.setStrategies(strategies)
        case .just:
            return self
        case let .sequence(length, elements, meta):
            let newMeta = ChoiceMetadata(validRanges: meta.validRanges, strategies: ShrinkingStrategy.sequences)
            return .sequence(length: length, elements: elements.map { $0.resetStrategies() }, newMeta)
        case let .branch(label, children):
            return .branch(label: label, children: children.map { $0.resetStrategies() })
        case let .group(array):
            return .group(array.map { $0.resetStrategies() })
        case let .important(element):
            let importantStrategies = [ShrinkingStrategy.binary, .saturation, .ultraSaturation]
            return .important(element.setStrategies(importantStrategies) )
        }
    }
}
