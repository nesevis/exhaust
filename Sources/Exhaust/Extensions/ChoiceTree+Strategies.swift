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
                .sequence(length: 1, elements: Array(elements.prefix(1)), meta).resetStrategies(direction: .towardsLowerBound),
                // The last element
                .sequence(length: 1, elements: Array(elements.suffix(1)), meta).resetStrategies(direction: .towardsLowerBound)
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
                .sequence(length: length - 1, elements: Array(elements.dropFirst()), meta).resetStrategies(direction: .towardsLowerBound),
                .sequence(length: length - 1, elements: Array(elements.dropLast()), meta).resetStrategies(direction: .towardsLowerBound)
            ]
        default:
            fatalError("\(#function) should not be called directly for \(self)!")
        }
    }
    
    func binary(for direction: ShrinkingDirection) -> [ChoiceTree] {
        switch self {
        case let .choice(value, metadata):
            return value.binary(for: metadata.validRanges, direction: direction)
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
                    return .sequence(length: length, elements: subArray, metadata).resetStrategies(direction: direction)
                }
        default:
            fatalError("\(#function) should not be called directly for \(self)!")
        }
    }
    
    func saturation(for direction: ShrinkingDirection) -> [ChoiceTree] {
        switch self {
        case let .choice(value, metadata):
            return value.saturation(for: metadata.validRanges, direction: direction)
                // FIXME: Reset strategies here?
                .map { .choice($0, metadata).resetStrategies(direction: direction) }
        case let .sequence(length, elements, metadata):
            guard length > 1 else {
                return []
            }
            
            let chunks = elements.evenlyChunked(in: Int(length) / 10)
            
            return chunks
                .filter { ChoiceValue(UInt64($0.count)).fits(in: metadata.validRanges) }
                .map { chunk in
                        .sequence(length: UInt64(chunk.count), elements: Array(chunk), metadata)
                            .resetStrategies(direction: direction)
                }
        default:
            fatalError("\(#function) should not be called directly for \(self)!")
        }
    }
    
    func ultraSaturation(for direction: ShrinkingDirection) -> [ChoiceTree] {
        switch self {
        case let .choice(value, metadata):
            return value.ultraSaturation(for: metadata.validRanges, direction: direction)
                .map { .choice($0, metadata) }
        case .sequence:
            return self.boundaries
        default:
            fatalError("\(#function) should not be called directly for \(self)!")
        }
    }
    
    func setStrategies(_ strategies: [any TemporaryDualPurposeStrategy]) -> Self {
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
        case let .important(element), let .selected(element):
            return .important(element.setStrategies(strategies))
        case let .getSize(size):
            return .getSize(size)
        case let .resize(newSize, choices):
            return .resize(newSize: newSize, choices: choices.map { $0.setStrategies(strategies) })
        }
    }
    
    
    func adjustRangeBasedOnValue() -> Self {
        switch self {
        case .choice(let choiceValue, let choiceMetadata):
            fatalError()
        case .just:
            fatalError()
        case .sequence(let length, let elements, let choiceMetadata):
            fatalError()
        case .branch(let label, let children):
            fatalError()
        case .group(let array):
            fatalError()
        case .important(let choiceTree):
            fatalError()
        case .selected(let choiceTree):
            fatalError()
        case .getSize(_):
            fatalError()
        case .resize(newSize: _, choices: _):
            fatalError()
        }
    }
    
    func resetStrategies(direction: ShrinkingDirection) -> Self {
        // FIXME: Do we need to reset elements recursively here?
        switch self {
        case .choice:
            return self.setStrategiesForRangeAndType(direction: direction)
        case .just:
            return self
        case let .sequence(length, elements, meta):
            return .sequence(length: length, elements: elements, meta)
                .setStrategiesForRangeAndType(direction: direction)
        case let .branch(label, children):
            return self
        case let .group(array):
            return self
        case let .important(element), let .selected(element):
            return .important(element.setStrategiesForRangeAndType(direction: direction))
        case let .getSize(size):
            return .getSize(size)
        case let .resize(newSize, choices):
            return .resize(newSize: newSize, choices: choices.map { $0.resetStrategies(direction: direction) })
        }
    }
    
    private func setStrategiesForRangeAndType(direction: ShrinkingDirection) -> Self {
        guard let range = self.effectiveRange else {
            return self
        }
        switch self {
        case .choice:
            var importantStrategies = [any TemporaryDualPurposeStrategy]()
            switch range {
            case ..<0.1:
                print("Reached an appropriate level of precision")
                break
            case 0.1..<1:
                importantStrategies.append(UltraSaturationReducerStrategy(direction: direction))
            case 1:
                // This is exactly one
                break
            case 1..<50_000:
                importantStrategies.append(SaturationReducerStrategy(direction: direction))
                importantStrategies.append(UltraSaturationReducerStrategy(direction: direction))
            default:
//                importantStrategies.append(SpreadReducerStrategy(direction: direction))
                importantStrategies.append(BinaryReducerStrategy(direction: direction))
                importantStrategies.append(SaturationReducerStrategy(direction: direction))
                importantStrategies.append(UltraSaturationReducerStrategy(direction: direction))
            }
            return self.setStrategies(importantStrategies)
        case .sequence:
            var importantStrategies = [any TemporaryDualPurposeStrategy]()
            switch range {
            case ...1:
                // This one or empty
                break
            case 1..<50:
                importantStrategies.append(BoundaryReducerStrategy(direction: direction))
//                importantStrategies.append(SaturationReducerStrategy(direction: direction))
            default:
//                importantStrategies.append(SpreadReducerStrategy(direction: direction))
                importantStrategies.append(BinaryReducerStrategy(direction: direction))
                importantStrategies.append(SaturationReducerStrategy(direction: direction))
            }
            return self.setStrategies(importantStrategies)
        default:
            return self
        }
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
