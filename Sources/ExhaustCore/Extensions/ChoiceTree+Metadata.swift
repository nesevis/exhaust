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
            case let .choice(_, meta), let .sequence(_, meta):
                return meta
            case let .group(array, _, _):
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
        mappingLeaves { value, metadata in
            ChoiceValue(
                value.tag.makeConvertible(bitPattern64: value.reductionTarget(in: metadata.validRange)),
                tag: value.tag
            )
        }
    }

    /// Moves every ranged leaf to the bound farthest from its reduction target. An unranged leaf keeps its value.
    var maximizingLeaves: ChoiceTree {
        mappingLeaves { value, metadata in
            guard let range = metadata.validRange else {
                return value
            }
            let target = value.reductionTarget(in: range)
            let distanceBelow = target > range.lowerBound ? target - range.lowerBound : 0
            let distanceAbove = range.upperBound > target ? range.upperBound - target : 0
            let farthest = switch distanceAbove >= distanceBelow {
                case true:
                    range.upperBound
                case false:
                    range.lowerBound
            }
            return ChoiceValue(value.tag.makeConvertible(bitPattern64: farthest), tag: value.tag)
        }
    }

    /// Maps every leaf value, keeping structure so the flattened length is unchanged.
    func mappingLeaves(_ transform: (ChoiceValue, ChoiceMetadata) -> ChoiceValue) -> ChoiceTree {
        switch self {
            case let .choice(value, metadata):
                return .choice(transform(value, metadata), metadata)
            case .just, .getSize:
                return self
            case let .sequence(elements, metadata):
                return .sequence(
                    elements: elements.map { $0.mappingLeaves(transform) },
                    metadata: metadata
                )
            case let .branch(b):
                return .branch(
                    fingerprint: b.fingerprint,
                    weight: b.weight,
                    id: b.id,
                    branchCount: b.branchCount,
                    choice: b.choice.mappingLeaves(transform),
                    isSelected: b.isSelected
                )
            case let .group(children, isOpaque, _):
                return .group(
                    children.map { $0.mappingLeaves(transform) },
                    isOpaque: isOpaque
                )
            case let .resize(newSize, choices):
                return .resize(
                    newSize: newSize,
                    choices: choices.map { $0.mappingLeaves(transform) }
                )
            case let .bind(fingerprint, inner, bound):
                return .bind(
                    fingerprint: fingerprint,
                    inner: inner.mappingLeaves(transform),
                    bound: bound.mappingLeaves(transform)
                )
        }
    }
}
