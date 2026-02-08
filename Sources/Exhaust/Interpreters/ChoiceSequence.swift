//
//  ChoiceSequence.swift
//  Exhaust
//
//  Created by Chris Kolbu on 8/2/2026.
//

public enum ChoiceSequence {
    public enum SequenceValue: Hashable, Equatable {
        // The values within the `true`---`false` range are logically grouped
        case group(Bool)
        case value(Value)
        
        public var isValue: Bool {
            switch self {
            case .value: return true
            case .group: return false
            }
        }
    }
    
    public struct Value: Hashable, Equatable {
        let choice: ChoiceValue
        let validRanges: [ClosedRange<UInt64>]
    }
    public typealias Sequence = [SequenceValue]
    
    /// Flattens the tree structure of ``ChoiceTree`` to a flat list for mutation/shrinking purposes
    static func flatten(_ tree: ChoiceTree) -> Sequence {
        switch tree {
        case let .choice(value, meta):
            return [.value(.init(choice: value, validRanges: meta.validRanges))]
        case .just:
            return []
        case let .sequence(_, elements, _):
            return CollectionOfOne(.group(true))
                + elements.flatMap(flatten)
                + CollectionOfOne(.group(false))
        // Do we only do the selected branch?
        case let .branch(_, _, children):
            return CollectionOfOne(.group(true))
                + children.flatMap(flatten)
                + CollectionOfOne(.group(false))
        case let .group(array):
            return CollectionOfOne(.group(true))
                + array.flatMap(flatten)
                + CollectionOfOne(.group(false))
        case .getSize:
            return []
        case let .resize(_, choices):
            return CollectionOfOne(.group(true))
                + choices.flatMap(flatten)
                + CollectionOfOne(.group(false))
        // Do we preserve these markers?
        case let .important(tree):
            return flatten(tree)
        case let .selected(tree):
            return flatten(tree)
        }
    }
}
