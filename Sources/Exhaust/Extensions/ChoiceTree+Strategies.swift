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
                .filter { $0.fits(in: metadata.validRanges) }
                .map { .choice($0, metadata) }
        case let .sequence(length, elements, meta):
            guard length > 0 else {
                return []
            }
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
                .filter { $0.fits(in: metadata.validRanges) }
                .map { .choice($0, metadata) }
        case let .sequence(length, elements, meta):
            guard length > 1 else {
                return []
            }
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
        case let .sequence(length, elements, metadata):
            guard length > 1 else {
                return []
            }
            let halvingPoint = length / 2
            return [(halvingPoint, true), (length - halvingPoint, false)]
                .filter { ChoiceValue($0.0).fits(in: metadata.validRanges) }
                .map { length, prefix in
                    let subArray = prefix
                        ? Array(elements.prefix(Int(length)))
                        : Array(elements.suffix(Int(length)))
                    return .sequence(length: length, elements: subArray, metadata).resetStrategies()
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
        case let .sequence(length, elements, metadata):
            guard length > 1 else {
                return []
            }
            
            let chunks = elements.evenlyChunked(in: Int(length) / 10)
            
            return chunks
                .filter { ChoiceValue($0.count).fits(in: metadata.validRanges) }
                .map { chunk in
                    .sequence(length: UInt64(chunk.count), elements: Array(chunk), metadata).resetStrategies()
                }
        default:
            fatalError("\(#function) should not be called directly for \(self)!")
        }
    }
    
    var ultraSaturation: [ChoiceTree] {
        switch self {
        case let .choice(value, metadata):
            return value.ultraSaturation(for: metadata.validRanges)
                .map { .choice($0, metadata) }
        case .sequence:
            return self.boundaries
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
            let newMeta = ChoiceMetadata(validRanges: meta.validRanges, strategies: strategies)
            return .sequence(length: length, elements: elements/*.map { $0.setStrategies(strategies) }*/, newMeta)
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
        case .choice:
            return self.setStrategiesForRangeAndType()
        case .just:
            return self
        case let .sequence(length, elements, meta):
            return .sequence(length: length, elements: elements.map { $0.resetStrategies() }, meta)
                .setStrategiesForRangeAndType()
        case let .branch(label, children):
            return .branch(label: label, children: children.map { $0.resetStrategies() })
        case let .group(array):
            return .group(array.map { $0.resetStrategies() })
        case let .important(element):
            return .important(element.setStrategiesForRangeAndType())
        }
    }
    
    private func setStrategiesForRangeAndType() -> Self {
        guard let range = self.effectiveRange else {
            fatalError("\(#function) should not be called")
            return self
        }
        switch self {
        case .choice:
            var importantStrategies = [ShrinkingStrategy]()
            switch range {
            case ..<0.1:
                print("Reached an appropriate level of precision")
                break
            case 0.1..<1:
                importantStrategies.append(.ultraSaturation)
            case 1:
                // This is exactly one
                break
            case 1..<50:
                importantStrategies.append(contentsOf: [.saturation, .ultraSaturation])
            default:
                importantStrategies.append(contentsOf: [.binary, .saturation, .ultraSaturation])
            }
            return self.setStrategies(importantStrategies)
        case .sequence:
            var importantStrategies = [ShrinkingStrategy]()
            switch range {
            case ...1:
                // This one or empty
                break
            case 1..<50:
                importantStrategies.append(contentsOf: [.boundaries, .saturation])
            default:
                importantStrategies.append(contentsOf: [.binary, .saturation])
            }
            return self.setStrategies(importantStrategies)
        default:
            return self
        }
    }
    
    private var effectiveRange: Double? {
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
                return upper - lower
            case .character(let character):
                guard let range = choiceMetadata.validRanges.first(where: { $0.contains(character.bitPattern64) }) else {
                    fatalError("\(#function) this should not happen")
                }
                return Double(UInt32(bitPattern64: range.upperBound - range.lowerBound))
            }
        case .sequence(_, let elements, let choiceMetadata):
            return Double(choiceMetadata.validRanges[0].count)
        default:
            return nil
        }
    }
}
