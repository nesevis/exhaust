////
////  ChoiceTree+Shortlex.swift
////  Exhaust
////
////  Created by Chris Kolbu on 29/7/2025.
////

package extension ChoiceTree {
    /// Extracts the ``ChoiceMetadata`` for this tree node, falling back to the first child whose valid range is non-nil for group nodes that lack their own metadata.
    var metadata: ChoiceMetadata {
        switch self {
        case let .choice(_, meta), let .sequence(_, _, meta):
            return meta
        case let .group(array, _):
            if let meta = array.first(where: { $0.metadata.validRange != nil })?.metadata {
                return meta
            }
            return ChoiceMetadata(validRange: nil)
        case let .bind(_, _, bound):
            return bound.metadata
        default:
            return ChoiceMetadata(validRange: nil)
        }
    }

    /// Returns a copy of the tree with every `.choice` node's value replaced by its reduction target. Strips PRNG-derived noise so shortlex comparison reflects only structural difference.
    var minimizingLeaves: ChoiceTree {
        switch self {
        case let .choice(value, metadata):
            let targetBitPattern = value.reductionTarget(in: metadata.validRange)
            let targetValue = ChoiceValue(
                value.tag.makeConvertible(bitPattern64: targetBitPattern),
                tag: value.tag
            )
            return .choice(targetValue, metadata)
        case .just, .getSize:
            return self
        case let .sequence(length, elements, metadata):
            return .sequence(
                length: length,
                elements: elements.map(\.minimizingLeaves),
                metadata
            )
        case let .branch(fingerprint, weight, id, branchCount, choice, isSelected):
            return .branch(
                fingerprint: fingerprint,
                weight: weight,
                id: id,
                branchCount: branchCount,
                choice: choice.minimizingLeaves,
                isSelected: isSelected
            )
        case let .group(children, isOpaque):
            return .group(
                children.map(\.minimizingLeaves),
                isOpaque: isOpaque
            )
        case let .resize(newSize, choices):
            return .resize(
                newSize: newSize,
                choices: choices.map(\.minimizingLeaves)
            )
        case let .bind(fingerprint, inner, bound):
            return .bind(
                fingerprint: fingerprint,
                inner: inner.minimizingLeaves,
                bound: bound.minimizingLeaves
            )
        }
    }
}
