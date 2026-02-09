//
//  ChoiceSequence.swift
//  Exhaust
//
//  Created by Chris Kolbu on 8/2/2026.
//

public enum ChoiceSequence {
    public enum SequenceValue: Hashable, Equatable {
        /// The elements within the `true`---`false` range are logically grouped
        case group(Bool)
        /// Values that repeat within a sequence
        /// The elements within the `true`---`false` range are elements of the sequence
        case sequence(Bool)
        /// A marker for a branching choice.
        /// The `Value` contains the chosen index in the array
        /// This marker has no explicit closing marker
        case branch(Value)
        /// Individual values
        case value(Value)
        
        public var isValue: Bool {
            switch self {
            case .value: return true
            case .group: return false
            case .sequence: return false
            case .branch: return false
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
            return CollectionOfOne(.sequence(true))
                + elements.flatMap(flatten)
                + CollectionOfOne(.sequence(false))
        // Do we only do the selected branch?
        case let .branch(_, _, gen):
             return flatten(gen)
        case let .group(array):
            if
                array.allSatisfy({ $0.isBranch || $0.isSelected }),
                case let .selected(.branch(_, label, choice)) = array.first(where: \.isSelected),
                choice.isCharacterChoice == false
            {
                let value = SequenceValue.branch(.init(
                    // The label is one-indexed
                    choice: .init(label - 1, tag: .uint64),
                    validRanges: []
                ))
                return [.group(true), value]
                    + array.flatMap(flatten)
                    + [.group(false)]
            }
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
    
    static func validate(_ sequence: ChoiceSequence.Sequence) -> Bool {
        var sequenceCount = 0
        var groupCount = 0
        for element in sequence {
            switch element {
            case .sequence(true):
                sequenceCount += 1
            case .sequence(false):
                sequenceCount -= 1
            case .group(true):
                groupCount += 1
            case .group(false):
                groupCount -= 1
            case .value, .branch:
                break
            }
        }
        return sequenceCount == 0 && groupCount == 0
    }
    
    // Claude opus

    public struct ChoiceSpan {
        let kind: ChoiceSequence.SequenceValue
        let range: ClosedRange<Int>
        let depth: Int
    }

    public static func extractSpans(from sequence: ChoiceSequence.Sequence) -> [ChoiceSpan] {
        var spans: [ChoiceSpan] = []
        var stack: [(kind: ChoiceSequence.SequenceValue, start: Int)] = []
        // Maps stack depth to the span indices of children
        // collected while that frame was open
        var childrenAtDepth: [[Int]] = []

        for (i, entry) in sequence.enumerated() {
            switch entry {
            case .sequence(true):
                stack.append((.sequence(true), i))
                childrenAtDepth.append([])

            case .group(true):
                stack.append((.group(true), i))
                childrenAtDepth.append([])

            case .sequence(false), .group(false):
                guard let frame = stack.popLast() else { continue }

                let spanIndex = spans.count
                spans.append(ChoiceSpan(
                    kind: frame.kind,
                    range: frame.start...i,
                    depth: stack.count
                ))

                // Register this span as a child of the enclosing frame
                if !childrenAtDepth.isEmpty {
                    childrenAtDepth[childrenAtDepth.count - 1].append(spanIndex)
                }

            case .value, .branch:
                break
            }
        }

        return spans.reversed()
    }
}

extension ChoiceSequence.Sequence {
    var shortString: String {
        self.map { element in
            switch element {
            case .group(true):
                return "("
            case .group(false):
                return ")"
            case .sequence(true):
                return "["
            case .sequence(false):
                return "]"
            case .value:
                return "V"
            case let .branch(value):
                return "B\(value.choice.convertible):"
            }
        }.joined()
    }
}
