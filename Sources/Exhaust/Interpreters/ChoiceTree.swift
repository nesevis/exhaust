//
//  ChoiceTree.swift
//  Exhaust
//
//  Created by Chris Kolbu on 16/7/2025.
//

import Foundation

enum ChoiceTree: Hashable, Equatable, Sendable {
    /// A primitive choice, typically a number or a high-level semantic label.
    case choice(ChoiceValue, ChoiceMetadata)
    
    /// A deterministic or constant value that can't be shrunk
    /// This is encoded into the generator, and doesn't need to be part of the ``ChoiceTree``
    case just(String)
    
    /// A node that represents the generation of a sequence. It explicitly
    /// captures the length and the choice trees for each of its elements.
    indirect case sequence(length: UInt64, elements: [ChoiceTree], ChoiceMetadata)
    
    /// A node that represents a branching choice made via `pick`.
    indirect case branch(label: UInt64, children: [ChoiceTree])
    
    /// Represents a nested group of choices that usually represent objects or tuples
    indirect case group([ChoiceTree])
    
    /// Used only for test case reduction. Represents a value that is known to have affected the property being tested against
    indirect case important(ChoiceTree)
    
    /// Used only for replay. Represents the selected branch in a ``group`` of ``branch``es.
    indirect case selected(ChoiceTree)
}

extension ChoiceTree {
    var isImportant: Bool {
        if case .important = self {
            return true
        }
        return false
    }
    
    var isSelected: Bool {
        if case .selected = self {
            return true
        }
        return false
    }
    
    var isBranch: Bool {
        if case .branch = self {
            return true
        }
        return false
    }
    
    var isJust: Bool {
        if case .just = self {
            return true
        }
        return false
    }
    
    var structuralComplexity: UInt64 {
        switch self {
        case .choice:
            return 1
        case .just:
            return 0
        case .sequence(_, let elements, _):
            return 2 + elements.map(\.structuralComplexity).reduce(0, +)
        case .branch(_, let children):
            return 3 + children.map(\.structuralComplexity).reduce(0, +)
        case .group(let array):
            return 1 + array.map(\.structuralComplexity).reduce(0, +)
        case .important(let choiceTree), .selected(let choiceTree):
            return choiceTree.structuralComplexity
        }
    }
    
    var complexity: UInt64 {
        switch self {
        case let .choice(value, _):
            return value.complexity
        case .just:
            return 0
        case .sequence(let length, var elements, _):
            var complexity = UInt64(0)
            while elements.isEmpty == false {
                let element = elements.removeLast()
                let elementComplexity = element.complexity
                if complexity &+ elementComplexity < complexity {
                    return UInt64.max
                }
                complexity += elementComplexity
            }
            let includingLength = complexity &+ length
            if includingLength < complexity {
                return UInt64.max
            }
            return includingLength
        case .branch(_, var elements), .group(var elements):
            var complexity = UInt64(0)
            while elements.isEmpty == false {
                let element = elements.removeLast()
                let elementComplexity = element.complexity
                if complexity &+ elementComplexity < complexity {
                    return UInt64.max
                }
                complexity += elementComplexity
            }
            return complexity
        case let .important(value), let .selected(value):
            return value.complexity
        }
    }
}

// Functor
extension ChoiceTree {
    /// Recursively transforms a `ChoiceTree` by applying a given closure to each node.
    ///
    /// - Parameter transform: A closure that takes a `ChoiceTree` and returns a transformed `ChoiceTree`.
    /// - Returns: A new `ChoiceTree` with the transform applied to all its nodes and their children.
    func map(_ transform: (ChoiceTree) throws -> ChoiceTree) rethrows -> ChoiceTree {
        let transformedNode = try transform(self)

        switch transformedNode {
        case .choice, .just:
            // For leaf nodes, return the transformed node directly.
            return transformedNode
        case let .sequence(length, elements, metadata):
            // For a sequence, recursively map over its elements.
            return try .sequence(length: length, elements: elements.map { try $0.map(transform) }, metadata)
        case let .branch(label, children):
            // For a branch, recursively map over its children.
            return try .branch(label: label, children: children.map { try $0.map(transform) })
        case let .group(children):
            // For a group, recursively map over its children.
            return try .group(children.map { try $0.map(transform) })
        case let .important(child):
            // For an important node, recursively map over the locked child.
            return try .important(child.map(transform))
        case let .selected(child):
            // For a selected node, recursively map over the locked child.
            return try .selected(child.map(transform))
        }
    }
    
    func contains(_ predicate: (ChoiceTree) -> Bool) -> Bool {
        let selfResult = predicate(self)
        guard selfResult == false else {
            return true
        }

        switch self {
        case .choice, .just:
            return selfResult
        case let .sequence(_, elements, _), let .branch(_, elements), let .group(elements):
            // For a sequence, recursively map over its elements.
            return elements.contains(where: predicate)
        case let .important(child), let .selected(child):
            // For a locked node, recursively map over the locked child.
            return predicate(child)
        }
    }
    
    /// Recursively merges this tree with another, combining corresponding nodes using a provided closure.
        ///
        /// This function traverses both trees in parallel. When the node types match (e.g., both are `.sequence`),
        /// it recursively merges their children. When the node types differ or they are non-recursive leaves,
        /// it passes both nodes to the `combine` closure to determine the resulting node.
        ///
        /// The structure of `self` (the left-hand tree) is prioritized. For example, when merging two sequences,
        /// the resulting sequence will have the `length` and `metadata` of `self`.
        ///
        /// - Parameters:
        ///   - other: The tree to merge with (`ChoiceTree`).
        ///   - combine: A closure that takes two nodes (the one from `self` and the one from `other`)
        ///     and returns the desired resulting `ChoiceTree` for that position.
        /// - Returns: A new, merged `ChoiceTree`.
        func merge(with other: ChoiceTree, using combine: (ChoiceTree, ChoiceTree) -> ChoiceTree?) -> ChoiceTree {
            switch (self, other) {
            // --- Recursive Cases: Structures Match ---
            // If both are sequences, merge their elements recursively.
            case let (.sequence(lhsLength, lhsElements, metadata), .sequence(_, rhsElements, _)):
                if let containerResult = combine(self, other) {
                    return containerResult
                }
                // zip ensures we only iterate as long as both have elements.
                // The new children are created by recursively calling merge.
                let mergedElements = zip(lhsElements, rhsElements).map { (lhsElement, rhsElement) in
                    lhsElement.merge(with: rhsElement, using: combine)
                }
                // A new sequence is created, preserving the left tree's metadata.
                return .sequence(length: lhsLength, elements: mergedElements, metadata)

            // If both are branches, merge their children recursively.
            case let (.branch(label, lhsChildren), .branch(_, rhsChildren)):
                if let containerResult = combine(self, other) {
                    return containerResult
                }
                let mergedChildren = zip(lhsChildren, rhsChildren).map { (lhsChild, rhsChild) in
                    lhsChild.merge(with: rhsChild, using: combine)
                }
                // The new branch preserves the left tree's label.
                return .branch(label: label, children: mergedChildren)

            // If both are groups, merge their children recursively.
            case let (.group(lhsChildren), .group(rhsChildren)):
                if let containerResult = combine(self, other) {
                    return containerResult
                }
                let mergedChildren = zip(lhsChildren, rhsChildren).map { (lhsChild, rhsChild) in
                    lhsChild.merge(with: rhsChild, using: combine)
                }
                return .group(mergedChildren)

            // If both are locked, merge the inner child.
            case let (.important(lhsChild), .important(rhsChild)):
                if let containerResult = combine(self, other) {
                    return containerResult
                }
                return .important(lhsChild.merge(with: rhsChild, using: combine))

            // --- Base Case: Let the user's closure decide ---
            // This handles:
            //  - .choice vs .choice
            //  - .just vs .just
            //  - Any structural mismatch (e.g., .sequence vs .branch)
            default:
                // At any point of structural difference or at a leaf,
                // we stop recursing and delegate the decision to the user.
                return combine(self, other) ?? self
            }
        }
    
    /// Locks in values of `new` where there is a difference from `old`
    static func diffAndLockChanges(in new: ChoiceTree, from valid: ChoiceTree) -> ChoiceTree {
        new.merge(with: valid) {
            lhs,
            rhs in
            switch (lhs, rhs) {
            case let (.important(lhsValue), .important(rhsValue)):
                // Stop here
                return Self.diffAndLockChanges(in: lhsValue, from: rhsValue)
            case (.important, _):
                return lhs
            case let (.choice(lhsValue, _), .choice(rhsValue, _)):
                guard lhsValue != rhsValue else {
                    return lhs
                }
                // TODO: Decorate with whether we need to go down or up
                // 45_000 vs 0, so 0 triggered that this is important
                // We need to build a range from rhs...lhs
                let lhsRange = lhsValue.convertible.bitPattern64
                let rhsRange = rhsValue.convertible.bitPattern64
                let convertibleRange = min(lhsRange, rhsRange)...max(lhsRange, rhsRange)
                let meta = ChoiceMetadata(validRanges: [convertibleRange], strategies: [])
                return ChoiceTree.choice(lhsValue, meta)
                    .resetStrategies(direction: lhsValue.shrinkingDirection(given: rhsValue)) // This will apply strategies based on the effective range
            case let (.sequence(lhsLength, lhsElements, lhsMeta), .sequence(rhsLength, rhsElements, _)):
                // The sequence itself is important
                if lhsLength != rhsLength {
                    // TODO: Decorate with whether we need to go down or up
                    // We can now create a valid subrange for the length of this sequence
                    let newRange = min(lhsLength, rhsLength)...max(lhsLength, rhsLength)
                    // We know that the range has to be between what what's allowable and what failed
                    let meta = ChoiceMetadata(validRanges: [newRange], strategies: [])
                    return .important(.sequence(length: lhsLength, elements: lhsElements, meta))
                        .resetStrategies(direction: ChoiceValue(lhsLength).shrinkingDirection(given: ChoiceValue(rhsLength))) // This will apply strategies based on the effective range
                }
                // The sequence content is important
                if lhsElements.elementsEqual(rhsElements) == false {
                    let importantElements = zip(lhsElements, rhsElements).map { lhs, rhs in
                        ChoiceTree.diffAndLockChanges(in: lhs, from: rhs)
                    }
                    return .sequence(length: lhsLength, elements: importantElements, lhsMeta)
                }
                return nil
            default:
                return nil
            }
        }
    }
    
//    func diffMap(other: ChoiceTree, _ transform: (ChoiceTree, ChoiceTree) throws -> ChoiceTree) rethrows -> ChoiceTree {
//        self
//    }
}

extension ChoiceTree: CustomDebugStringConvertible {
    var prettyPrint: NSString {
        NSString(string: debugDescription)
    }
    
    var debugDescription: String {
        treeDescription(prefix: "", isLast: true)
    }
    
    private func treeDescription(prefix: String, isLast: Bool, isLocked: Bool = false, isSelected: Bool = false) -> String {
        let connector = isLast ? "└── " : "├── "
        let childPrefix = prefix + (isLast ? "    " : "│   ")
        let locked = isLocked ? "✨" : ""
        let selected = isSelected ? "✅" : ""
        
        switch self {
        case let .choice(value, _):
            switch value {
            case let .character(char):
                return prefix + connector + "\(locked)choice(char: \"\(char)\")\(locked)"
            case let .unsigned(uint):
                return prefix + connector + "\(locked)choice(unsigned:\(uint))\(locked)"
            case let .signed(int, _):
                return prefix + connector + "\(locked)choice(signed: \(int))\(locked)"
            case let .floating(float, _):
                return prefix + connector + "\(locked)choice(float: \(float))\(locked)"
            }
            
        case .just(let type):
            return prefix + connector + "just(\(type))"
            
        case let .sequence(length, elements, _):
            var result = prefix + connector + "\(locked)sequence(length: \(length))\(locked)"
            if case .choice(.character(_), _) = elements.first {
                // A special case displaying all the characters in a string inline
                let string = elements.map { choice in
                    switch choice {
                    case let .choice(.character(char), _), let .important(.choice(.character(char), _)):
                        return char
                    default:
                        fatalError("\(#function) Expected a homogenous array of characters!")
                    }
                }
                result += "\n\(childPrefix)└── choice([char]: \"\(String(string))\")"
            } else {
                for (index, element) in elements.enumerated() {
                    let isLastElement = index == elements.count - 1
                    result += "\n" + element.treeDescription(prefix: childPrefix, isLast: isLastElement)
                }
            }
            return result
            
        case let .branch(label, children):
            var result = prefix + connector + "\(selected)\(locked)branch(label: \(label))\(locked)"
            for (index, child) in children.enumerated() {
                let isLastChild = index == children.count - 1
                result += "\n" + child.treeDescription(prefix: childPrefix, isLast: isLastChild)
            }
            return result
            
        case let .group(children):
            var result = prefix + connector + "\(locked)group\(locked)"
            for (index, child) in children.enumerated() {
                let isLastChild = index == children.count - 1
                result += "\n" + child.treeDescription(prefix: childPrefix, isLast: isLastChild)
            }
            return result
        case let .important(value):
            return value.treeDescription(prefix: prefix, isLast: isLast, isLocked: true)
        case let .selected(value):
            return value.treeDescription(prefix: prefix, isLast: isLast, isSelected: true)
        }
    }
    
    var elementDescription: String {
        switch self {
        case .choice(let choiceValue, _):
            switch choiceValue {
            case .unsigned(let uInt64):
                return uInt64.description
            case .signed(let int, _):
                return int.description
            case .floating(let float, _):
                return float.description
            case .character(let character):
                return character.description
            }
        case .just(let type):
            return "just(\(type))"
        case .sequence(_, let elements, _):
            if case .choice(.character, _) = elements.first {
                return "\"\(elements.map(\.elementDescription).joined())\""
            }
            return "[" + elements.map(\.elementDescription).joined(separator: ", ") + "]"
        case .branch(let label, let children):
            return "\(label): \(children.map(\.elementDescription).joined(separator: " | "))"
        case .group(let array):
            return "{" + array.map(\.elementDescription).joined() + "}"
        case .important(let choiceTree), .selected(let choiceTree):
            return choiceTree.elementDescription
        }
    }
}
