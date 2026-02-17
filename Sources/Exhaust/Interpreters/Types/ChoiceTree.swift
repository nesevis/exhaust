//
//  ChoiceTree.swift
//  Exhaust
//
//  Created by Chris Kolbu on 16/7/2025.
//

import Algorithms
import CasePaths
import Foundation

@CasePathable
public enum ChoiceTree: Hashable, Equatable, Sendable {
    /// A primitive choice, typically a number or a high-level semantic label.
    case choice(ChoiceValue, ChoiceMetadata)

    /// A deterministic or constant value that can't be shrunk
    /// This is encoded into the generator, and doesn't need to be part of the ``ChoiceTree``
    /// The string value is a description of the value for debug purposes
    case just(String)

    /// A node that represents the generation of a sequence. It explicitly
    /// captures the length and the choice trees for each of its elements.
    indirect case sequence(length: UInt64, elements: [ChoiceTree], ChoiceMetadata)

    /// A node that represents a branching choice made via `pick`.
    indirect case branch(weight: UInt64, label: UInt64, choice: ChoiceTree)

    /// Represents a nested group of choices that usually represent objects or tuples
    indirect case group([ChoiceTree])

    /// Represents a size value retrieved from the generation context
    case getSize(UInt64)

    /// Represents a resized generation context with nested choices
    indirect case resize(newSize: UInt64, choices: [ChoiceTree])

    /// Used only for test case reduction. Represents a value that is known to have affected the property being tested against
    indirect case important(ChoiceTree)

    /// Used only for replay. Represents the selected branch in a ``group`` of ``branch``es.
    indirect case selected(ChoiceTree)
}

extension ChoiceTree {
    static let emptyJust = Self.just("")

    var isSizing: Bool {
        switch self {
        case .getSize, .resize:
            true
        default:
            false
        }
    }

    var isImportant: Bool {
        if case .important = self {
            return true
        }
        return false
    }

    var isChoice: Bool {
        if case .choice = self {
            return true
        }
        return false
    }

    var isCharacterChoice: Bool {
        if case .choice(.character, _) = self {
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
            1
        case .just:
            0
        case let .sequence(_, elements, _):
            2 + elements.map(\.structuralComplexity).reduce(0, +)
        case let .branch(_, _, gen):
            3 + gen.structuralComplexity
        case let .group(array):
            1 + array.map(\.structuralComplexity).reduce(0, +)
        case let .important(choiceTree), let .selected(choiceTree):
            choiceTree.structuralComplexity
        case .getSize:
            1
        case let .resize(_, choices):
            2 + choices.map(\.structuralComplexity).reduce(0, +)
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
        case let .branch(_, _, gen):
            return gen.complexity
        case var .group(elements):
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
        case let .getSize(size):
            return size
        case let .resize(_, choices):
            var complexity = UInt64(0)
            for choice in choices {
                let choiceComplexity = choice.complexity
                if complexity &+ choiceComplexity < complexity {
                    return UInt64.max
                }
                complexity += choiceComplexity
            }
            return complexity
        }
    }
}

/// Functor
extension ChoiceTree {
    /// Recursively transforms a `ChoiceTree` by applying a given closure to each node.
    ///
    /// - Parameter transform: A closure that takes a `ChoiceTree` and returns a transformed `ChoiceTree`.
    /// - Returns: A new `ChoiceTree` with the transform applied to all its nodes and their children.
    func map(_ transform: (ChoiceTree) throws -> ChoiceTree) rethrows -> ChoiceTree {
        let transformedNode = try transform(self)

        switch transformedNode {
        case .choice, .just, .getSize:
            // For leaf nodes, return the transformed node directly.
            return transformedNode
        case let .sequence(length, elements, metadata):
            // For a sequence, recursively map over its elements.
            return try .sequence(length: length, elements: elements.map { try $0.map(transform) }, metadata)
        case let .branch(weight, label, choice):
            // For a branch, recursively map over its children.
            return try .branch(weight: weight, label: label, choice: transform(choice))
        case let .group(children):
            // For a group, recursively map over its children.
            return try .group(children.map { try $0.map(transform) })
        case let .important(child):
            // For an important node, recursively map over the locked child.
            return try .important(child.map(transform))
        case let .selected(child):
            // For a selected node, recursively map over the locked child.
            return try .selected(child.map(transform))
        case let .resize(newSize, choices):
            // For a resize node, recursively map over its choices.
            return try .resize(newSize: newSize, choices: choices.map { try $0.map(transform) })
        }
    }

    func contains(_ predicate: (ChoiceTree) -> Bool) -> Bool {
        let selfResult = predicate(self)
        guard selfResult == false else {
            return true
        }

        switch self {
        case .choice, .just, .getSize:
            return selfResult
        case let .branch(_, _, gen):
            return predicate(gen)
        case let .sequence(_, elements, _), let .group(elements):
            // For a sequence, recursively map over its elements.
            return elements.contains(where: predicate)
        case let .important(child), let .selected(child):
            // For a locked node, recursively map over the locked child.
            return predicate(child)
        case let .resize(_, choices):
            return choices.contains { $0.contains(predicate) }
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
            let mergedElements = zip(lhsElements, rhsElements).map { lhsElement, rhsElement in
                lhsElement.merge(with: rhsElement, using: combine)
            }
            // A new sequence is created, preserving the left tree's metadata.
            return .sequence(length: lhsLength, elements: mergedElements, metadata)

        // If both are branches, merge their children recursively.
        case let (.branch(weight, label, lhsChoice), .branch(_, _, rhsChoice)):
            if let containerResult = combine(self, other) {
                return containerResult
            }
            let merged = lhsChoice.merge(with: rhsChoice, using: combine)
            // The new branch preserves the left tree's weight and label.
            return .branch(weight: weight, label: label, choice: merged)

        // If both are groups, merge their children recursively.
        case let (.group(lhsChildren), .group(rhsChildren)):
            if let containerResult = combine(self, other) {
                return containerResult
            }
            let mergedChildren = zip(lhsChildren, rhsChildren).map { lhsChild, rhsChild in
                lhsChild.merge(with: rhsChild, using: combine)
            }
            return .group(mergedChildren)

        // If both are locked, merge the inner child.
        case let (.important(lhsChild), .important(rhsChild)):
            if let containerResult = combine(self, other) {
                return containerResult
            }
            return .important(lhsChild.merge(with: rhsChild, using: combine))

        // If both are resize, merge their choices recursively.
        case let (.resize(lhsSize, lhsChoices), .resize(_, rhsChoices)):
            if let containerResult = combine(self, other) {
                return containerResult
            }
            let mergedChoices = zip(lhsChoices, rhsChoices).map { lhsChoice, rhsChoice in
                lhsChoice.merge(with: rhsChoice, using: combine)
            }
            return .resize(newSize: lhsSize, choices: mergedChoices)

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

    func mapWhereDifferent(to other: ChoiceTree, using transform: (ChoiceTree, ChoiceTree) -> ChoiceTree?) -> ChoiceTree {
        merge(with: other) { lhs, rhs in
            // Only disimilar types
            switch (lhs, rhs) {
            // Unwrap important markers
            case let (.important(lhsValue), .important(rhsValue)) where lhsValue.typeId == rhsValue.typeId && lhsValue != rhsValue:
                return transform(lhsValue, rhsValue).map { .important($0) }
            case let (.important(lhsValue), _) where lhsValue.typeId == rhs.typeId && lhsValue != rhs:
                return transform(lhsValue, rhs).map { .important($0) }
            case let (_, .important(rhsValue)) where self.typeId == rhsValue.typeId && lhs != rhsValue:
                return transform(lhs, rhsValue)
            // Unwrap selected markers
            case let (.selected(lhsValue), .selected(rhsValue)) where lhsValue.typeId == rhsValue.typeId && lhsValue != rhsValue:
                return transform(lhsValue, rhsValue).map { .selected($0) }
            case let (.selected(lhsValue), _) where lhsValue.typeId == rhs.typeId && lhsValue != rhs:
                return transform(lhsValue, rhs).map { .selected($0) }
            case let (_, .selected(rhsValue)) where self.typeId == rhsValue.typeId && lhs != rhsValue:
                return transform(lhs, rhsValue)
            case (.choice, .choice) where lhs.typeId == rhs.typeId && lhs != rhs:
                return transform(lhs, rhs)
            case let (.sequence(lLength, lElements, lMeta), .sequence(_, rElements, _)) where rhs != lhs:
                let transformedElements = zip(lElements, rElements).map { lhs, rhs in
                    lhs.mapWhereDifferent(to: rhs, using: transform)
                }
                let newLhs = ChoiceTree.sequence(
                    length: lLength,
                    elements: transformedElements.isEmpty ? lElements : transformedElements,
                    lMeta,
                )
                return transform(newLhs, rhs)
            case let (.group(lhs), .group(rhs)):
                let transformedGroup = zip(lhs, rhs).map { lhs, rhs in
                    lhs.mapWhereDifferent(to: rhs, using: transform)
                }
                return ChoiceTree.group(transformedGroup)
            default:
                return nil
            }
        }
    }
}

extension ChoiceTree: CustomDebugStringConvertible {
    var prettyPrint: NSString {
        NSString(string: debugDescription)
    }

    public var debugDescription: String {
        treeDescription(prefix: "", isLast: true)
    }

    private func treeDescription(prefix: String, isLast: Bool, isLocked: Bool = false, isSelected: Bool = false) -> String {
        let connector = isLast ? "└── " : "├── "
        let childPrefix = prefix + (isLast ? "    " : "│   ")
        let locked = isLocked ? "✨" : ""
        let selected = isSelected ? "✅" : ""

        switch self {
        case let .choice(value, meta):
            let displayRange = value.displayRange(meta.validRanges[0])
            switch value {
            case let .character(char):
                return prefix + connector + "\(locked)choice(char: \"\(char)\")\(locked) \(displayRange)"
            case let .unsigned(uint, _):
                return prefix + connector + "\(locked)choice(unsigned:\(uint))\(locked) \(displayRange)"
            case let .signed(int, _, _):
                return prefix + connector + "\(locked)choice(signed: \(int))\(locked) \(displayRange)"
            case let .floating(float, _, _):
                return prefix + connector + "\(locked)choice(float: \(float))\(locked) \(displayRange)"
            }

        case let .just(type):
            return prefix + connector + "just(\(type))"

        case let .sequence(length, elements, meta):
            var result = prefix + connector + "\(locked)sequence(length: \(length))\(locked) \(meta.validRanges[0])"
            if case let .group(array) = elements.first,
               // Dropping the first one as it is a getSize
               case let .group(branches) = array.dropFirst().first,
               case let .branch(_, _, gen) = branches.first(where: { $0.isSelected == false }),
               case .choice = gen
            {
                // A special case displaying all the characters in a string inline
                let characters = elements.dropFirst().compactMap { element in
                    if case let .group(array) = element,
                       case let .group(branches) = array.dropFirst().first,
                       // Why are we getting a nonselected branch?
                       // FIXME: The assumption that the character value of all branches is identical no longer holds with the Value|ChoiceTree generator, and this special case is broken because reflected generators come back as all being selected now :|
                       case let .branch(_, _, gen) = branches.first(where: { $0.isSelected == false }),
                       case let .choice(.character(char), _) = gen
                    {
                        return char
                    }
                    return nil
                }
                result += "\n\(childPrefix)└── choice([char]: \"\(String(characters))\")"
            } else {
                for (index, element) in elements.enumerated() {
                    let isLastElement = index == elements.count - 1
                    result += "\n" + element.treeDescription(prefix: childPrefix, isLast: isLastElement)
                }
            }
            return result

        case let .branch(weight, label, gen):
            var result = prefix + connector + "\(selected)\(locked)branch(label: \(label), weight: \(weight))\(locked)"
            result += "\n" + gen.treeDescription(prefix: childPrefix, isLast: true)
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

        case .getSize:
            return prefix + connector + "getSize(?)"

        case let .resize(newSize, choices):
            var result = prefix + connector + "resize(\(newSize))"
            for (index, choice) in choices.enumerated() {
                let isLastChoice = index == choices.count - 1
                result += "\n" + choice.treeDescription(prefix: childPrefix, isLast: isLastChoice)
            }
            return result
        }
    }

    var elementDescription: String {
        switch self {
        case let .choice(choiceValue, _):
            switch choiceValue {
            case let .unsigned(uInt64, _):
                return uInt64.description
            case let .signed(int, _, _):
                return int.description
            case let .floating(float, _, _):
                return float.description
            case let .character(character):
                return character.description
            }
        case let .just(type):
            return "just(\(type))"
        case let .sequence(_, elements, _):
            if case .choice(.character, _) = elements.first {
                return "\"\(elements.map(\.elementDescription).joined())\""
            }
            return "[" + elements.map(\.elementDescription).joined(separator: ", ") + "]"
        case let .branch(weight, label, gen):
            return "\(weight),\(label): \(gen.elementDescription)"
        case let .group(array):
            return "{" + array.map(\.elementDescription).joined() + "}"
        case let .important(choiceTree), let .selected(choiceTree):
            return choiceTree.elementDescription
        case let .getSize(size):
            return "getSize(\(size))"
        case let .resize(newSize, choices):
            return "resize(\(newSize): [\(choices.map(\.elementDescription).joined(separator: ", "))])"
        }
    }

    /// Recursively unwraps wrapper nodes (selected, important) to get to the core content
    var unwrapped: ChoiceTree {
        switch self {
        case let .selected(inner), let .important(inner):
            inner.unwrapped
        default:
            self
        }
    }

    var isPickOfJusts: Bool {
        guard case let .group(array) = self else {
            return false
        }

        // Unwrap all children and check if they're branches containing just values
        let unwrappedChildren = array.map(\.unwrapped)

        // Check if we have at least one branch and all unwrapped children are branches
        guard unwrappedChildren.contains(where: \.isBranch),
              unwrappedChildren.allSatisfy({ $0.isBranch || $0.isSizing })
        else {
            return false
        }

        // Additional restriction: we should have only one selected branch at a time
        // This distinguishes genuine pick-of-justs from string character selections
        let selectedCount = array.count { element in
            if case .selected = element { return true }
            return false
        }
        guard selectedCount <= 1 else {
            return false
        }

        // Additional restriction: the just values should be meaningful discrete choices,
        // not character codes. We'll check if all just values are non-numeric strings
        // that could represent semantic choices (like "true"/"false", not character codes)
        for child in unwrappedChildren {
            if case let .branch(_, _, gen) = child {
                // All branch children should be just values with meaningful content
                guard gen.isJust else {
                    return false
                }

                // Check if the just values look like semantic choices rather than character data
                if case let .just(value) = gen {
                    // If the value is a single character or looks like character data,
                    // this is likely a string, not a semantic choice
                    if value.count == 1 || value.allSatisfy(\.isWhitespace) || value == "<value>" {
                        return false
                    }
                }
            }
        }

        return true
    }
}

extension ClosedRange where Bound == UInt64 {
    var midPoint: UInt64 {
        let span = upperBound - lowerBound
        return lowerBound + (span / 2)
    }
}
