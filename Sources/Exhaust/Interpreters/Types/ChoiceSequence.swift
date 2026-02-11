//
//  ChoiceSequence.swift
//  Exhaust
//
//  Created by Chris Kolbu on 8/2/2026.
//

public typealias ChoiceSequence = [ChoiceSequenceValue]

// MARK: - Helper functions

extension ChoiceSequence {
    /// Creates a projection of a `ChoiceTree` to a flat list
    init (_ tree: ChoiceTree) {
        self = Self.flatten(tree)
    }

    /// Flattens the tree structure of ``ChoiceTree`` to a flat list for mutation/shrinking purposes
//    @inlinable
    static func flatten(_ tree: ChoiceTree) -> ChoiceSequence {
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
                choice.isCharacterChoice == false // Do not add this marker for characters
            {
                let value = ChoiceSequenceValue.branch(.init(
                    // The label is one-indexed, take away one to make it correspond to the group array index
                    choice: .init(Int(label - 1), tag: .int),
                    validRanges: [UInt64(0)...UInt64(array.count - 1)]
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
    
    static func validate(_ sequence: ChoiceSequence) -> Bool {
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

    public struct ChoiceSpan: CustomDebugStringConvertible {
        public init(kind: ChoiceSequenceValue, range: ClosedRange<Int>, depth: Int) {
            self.kind = kind
            self.range = range
            self.depth = depth
        }
        
        let kind: ChoiceSequenceValue
        let range: ClosedRange<Int>
        let depth: Int
        
        public var debugDescription: String {
            "<\(kind.shortString)> \(range.lowerBound)...\(range.upperBound) @ \(depth)"
        }
    }

    @inlinable
    public static func extractContainerSpans(from sequence: ChoiceSequence) -> [ChoiceSpan] {
        var spans: [ChoiceSpan] = []
        var stack: [(kind: ChoiceSequenceValue, start: Int)] = []
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
    
    /// Returns the spans of values not inside groups
    @inlinable
    public static func extractValueSpans(from sequence: ChoiceSequence) -> [ChoiceSpan] {
        var spans: [ChoiceSpan] = []
        // Maps stack depth to the span indices of children
        // collected while that frame was open
        var depth = 0

        for (i, entry) in sequence.enumerated() {
            let preceding = i > 0 ? sequence[i - 1] : nil
            
            switch (preceding, entry) {
            case (nil, .value):
                spans.append(ChoiceSpan(kind: entry, range: i...i, depth: depth))
            case (.value, .value):
                spans.append(ChoiceSpan(kind: entry, range: i...i, depth: depth))
            case (.sequence(true), .value):
                spans.append(ChoiceSpan(kind: entry, range: i...i, depth: depth))
            case (.group(true), _), (.sequence(true), _):
                depth += 1
            case (.group(false), _), (.sequence(false), _):
                depth -= 1
            default:
                continue
            }
        }

        return spans.reversed()
    }
    
    var shortString: String {
        self.map(\.shortString).joined()
    }
    
    @inlinable
    mutating func removeSubranges(_ ranges: [ClosedRange<Int>]) {
        let set = RangeSet(ranges.map(\.asRange))
        self.removeSubranges(set)
    }
    
    func shortLexPrecedes(_ other: ChoiceSequence) -> Bool {
        // Shorter sequences are always better
        if self.count != other.count {
            return self.count < other.count
        }
        // Equal length compares lexicographically
        for (lhs, rhs) in zip(self, other) {
            switch lhs.shortLexCompare(rhs) {
            case .lt:
                return true
            case .gt:
                return false
            case .eq: continue
            }
        }
        return false // equal
    }
}
