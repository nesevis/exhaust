//
//  ChoiceTree.swift
//  Exhaust
//
//  Created by Chris Kolbu on 16/7/2025.
//

import Foundation

package enum ChoiceTree: Hashable, Equatable, Sendable {
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
    /// `siteID` identifies the pick site, `id` is the stable branch identifier, and `branchIDs` contains all ids in this pick site.
    indirect case branch(siteID: UInt64, weight: UInt64, id: UInt64, branchIDs: [UInt64], choice: ChoiceTree)

    /// Represents a nested group of choices that usually represent objects or tuples
    indirect case group([ChoiceTree])

    /// Represents a size value retrieved from the generation context
    case getSize(UInt64)

    /// Represents a resized generation context with nested choices
    indirect case resize(newSize: UInt64, choices: [ChoiceTree])

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

    /// Whether this tree contains any pick sites (`.branch` nodes).
    /// Short-circuits on the first pick found.
    var containsPicks: Bool {
        switch self {
        case .branch:
            true
        case .choice, .just, .getSize:
            false
        case let .selected(inner):
            inner.containsPicks
        case let .sequence(_, elements, _):
            elements.contains(where: \.containsPicks)
        case let .group(array):
            array.contains(where: \.containsPicks)
        case let .resize(_, choices):
            choices.contains(where: \.containsPicks)
        }
    }

    /// Returns the maximum `breadth × 2^pickDepth` across all pick sites,
    /// where pickDepth counts nested `.branch` levels.
    var pickComplexity: UInt64 {
        pickComplexityHelper(pickDepth: 0)
    }

    private func pickComplexityHelper(pickDepth: Int) -> UInt64 {
        switch self {
        case .choice, .just, .getSize:
            return 0
        case let .branch(_, _, _, branchIDs, choice):
            let here = UInt64(branchIDs.count) * (1 << pickDepth)
            let deeper = choice.pickComplexityHelper(pickDepth: pickDepth + 1)
            return max(here, deeper)
        case let .selected(inner):
            return inner.pickComplexityHelper(pickDepth: pickDepth)
        case let .sequence(_, elements, _):
            return elements.map { $0.pickComplexityHelper(pickDepth: pickDepth) }.max() ?? 0
        case let .group(array):
            return array.map { $0.pickComplexityHelper(pickDepth: pickDepth) }.max() ?? 0
        case let .resize(_, choices):
            return choices.map { $0.pickComplexityHelper(pickDepth: pickDepth) }.max() ?? 0
        }
    }
}

extension ChoiceTree {
    /// Recursively transforms a `ChoiceTree` by applying a given closure to each node.
    ///
    /// **Not currently used**
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
        case let .branch(siteID, weight, id, branchIDs, choice):
            // For a branch, recursively map over its children.
            return try .branch(siteID: siteID, weight: weight, id: id, branchIDs: branchIDs, choice: choice.map(transform))
        case let .group(children):
            // For a group, recursively map over its children.
            return try .group(children.map { try $0.map(transform) })
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
        case let .branch(_, _, _, _, gen):
            return gen.contains(predicate)
        case let .sequence(_, elements, _), let .group(elements):
            // For a sequence, recursively map over its elements.
            return elements.contains { $0.contains(predicate) }
        case let .selected(child):
            // For a locked node, recursively map over the locked child.
            return child.contains(predicate)
        case let .resize(_, choices):
            return choices.contains { $0.contains(predicate) }
        }
    }
}

extension ChoiceTree: CustomDebugStringConvertible {
    var prettyPrint: NSString {
        NSString(string: debugDescription)
    }

    package var debugDescription: String {
        treeDescription(prefix: "", isLast: true)
    }

    private func treeDescription(prefix: String, isLast: Bool, isSelected: Bool = false) -> String {
        let connector = isLast ? "└── " : "├── "
        let childPrefix = prefix + (isLast ? "    " : "│   ")
        let selected = isSelected ? "✅" : ""

        switch self {
        case let .choice(value, meta):
            let displayRange = value.displayRange(meta.validRanges[0])
            switch value {
            case let .character(char):
                return prefix + connector + "choice(char: \"\(char)\") \(displayRange)"
            case let .unsigned(uint, _):
                return prefix + connector + "choice(unsigned:\(uint)) \(displayRange)"
            case let .signed(int, _, _):
                return prefix + connector + "choice(signed: \(int)) \(displayRange)"
            case let .floating(float, _, _):
                return prefix + connector + "choice(float: \(float)) \(displayRange)"
            }

        case let .just(type):
            return prefix + connector + "just(\(type))"

        case let .sequence(length, elements, meta):
            var result = prefix + connector + "sequence(length: \(length)) \(meta.validRanges[0])"
            if case let .group(array) = elements.first,
               // Dropping the first one as it is a getSize
               case let .group(branches) = array.dropFirst().first,
               case let .branch(_, _, _, _, gen) = branches.first(where: { $0.isSelected == false }),
               case .choice = gen
            {
                // A special case displaying all the characters in a string inline
                let characters = elements.dropFirst().compactMap { element in
                    if case let .group(array) = element,
                       case let .group(branches) = array.dropFirst().first,
                       // Why are we getting a nonselected branch?
                       // FIXME: The assumption that the character value of all branches is identical no longer holds with the Value|ChoiceTree generator, and this special case is broken because reflected generators come back as all being selected now :|
                       case let .branch(_, _, _, _, gen) = branches.first(where: { $0.isSelected == false }),
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

        case let .branch(_, weight, id, branchIDs, gen):
            let index = branchIDs.firstIndex(of: id).map { $0 + 1 } ?? 0
            var result = prefix + connector + "\(selected)branch(id: \(id), index: \(index), weight: \(weight), count: \(branchIDs.count))"
            result += "\n" + gen.treeDescription(prefix: childPrefix, isLast: true)
            return result

        case let .group(children):
            var result = prefix + connector + "group"
            for (index, child) in children.enumerated() {
                let isLastChild = index == children.count - 1
                result += "\n" + child.treeDescription(prefix: childPrefix, isLast: isLastChild)
            }
            return result

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
        case let .branch(_, weight, id, _, gen):
            return "\(weight),\(id): \(gen.elementDescription)"
        case let .group(array):
            return "{" + array.map(\.elementDescription).joined() + "}"
        case let .selected(choiceTree):
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
        case let .selected(inner):
            inner.unwrapped
        default:
            self
        }
    }

    var branchId: UInt64? {
        if case let .branch(_, _, id, _, _) = unwrapped {
            return id
        }
        return nil
    }
}
