//
//  ChoiceTree.swift
//  Exhaust
//
//  Created by Chris Kolbu on 16/7/2025.
//

import Foundation

// MARK: - Academic Provenance

//
// The dissertation (Goldstein §3.3.3, §4.6) represents randomness as flat bit-string choice sequences. Exhaust adds this hierarchical ChoiceTree to preserve structural information (sequence boundaries, branch sites, nesting) for targeted shrinking and replay. The flat representation is in ChoiceSequence.swift.

/// A tree of choices that captures every decision made during generation.
///
/// Each node represents a single generation decision (a numeric choice, a branch selection, a sequence of elements, and so on). Interpreters walk this tree to replay, reflect, shrink, or analyze generated values.
public enum ChoiceTree: Hashable, Equatable, Sendable {
    /// A primitive choice, typically a number or a high-level semantic label.
    case choice(ChoiceValue, ChoiceMetadata)

    /// A deterministic or constant value that cannot be shrunk.
    ///
    /// This is encoded into the generator and does not need to be part of the ``ChoiceTree``.
    case just

    /// A node that represents the generation of a sequence. It explicitly captures the length and the choice trees for each of its elements.
    indirect case sequence(length: UInt64, elements: [ChoiceTree], ChoiceMetadata)

    /// A node that represents a branching choice made via ``pick``. ``siteID`` identifies the pick site, ``id`` is the stable branch identifier, and ``branchIDs`` contains all identifiers in this pick site.
    indirect case branch(
        siteID: UInt64,
        weight: UInt64,
        id: UInt64,
        branchIDs: [UInt64],
        choice: ChoiceTree
    )

    /// Represents a nested group of choices that usually represent objects or tuples.
    ///
    /// When `isOpaque` is `true`, coverage analysis skips the group's subtree entirely. This prevents high-lane compositions (for example SIMD8+) from exploding the parameter count in covering arrays, and isolates `getSize`-dependent scalars so they don't poison the rest of the property's analysis.
    indirect case group([ChoiceTree], isOpaque: Bool = false)

    /// Represents a size value retrieved from the generation context.
    case getSize(UInt64)

    /// Represents a resized generation context with nested choices.
    indirect case resize(newSize: UInt64, choices: [ChoiceTree])

    /// A bind node: the bound subtree's structure depends on the inner subtree's value.
    ///
    /// Produced by VACTI, reflection, and materialization for `.transform(.bind(...))` operations.
    /// In Phase 1, all reducer passes treat `.bind` like `.group([inner, bound])`.
    indirect case bind(inner: ChoiceTree, bound: ChoiceTree)

    /// Wraps the selected branch in a ``group`` of ``branch`` nodes. Produced by reflection and VACTI, consumed by replay and materialization.
    indirect case selected(ChoiceTree)
}

public extension ChoiceTree {
    /// The number of entries this tree produces when flattened to a ``ChoiceSequence``.
    ///
    /// Matches the count of `ChoiceSequence.flatten(self)` without allocating.
    /// Used by ``GuidedMaterializer`` to scope cursor consumption per zip child.
    var flattenedEntryCount: Int {
        switch self {
        case .choice: 1
        case .just: 1
        case .getSize: 0
        case let .sequence(_, elements, _):
            2 + elements.reduce(0) { $0 + $1.flattenedEntryCount } // open + elements + close
        case let .branch(_, _, _, _, choice):
            choice.flattenedEntryCount
        case let .group(array, _):
            if array.allSatisfy({ $0.isBranch || $0.isSelected }),
               case let .selected(.branch(_, _, _, _, choice)) = array.first(where: \.isSelected)
            {
                // group open + branch entry + choice + group close
                2 + 1 + choice.flattenedEntryCount
            } else {
                // group open + children + group close
                2 + array.reduce(0) { $0 + $1.flattenedEntryCount }
            }
        case let .bind(inner, bound):
            // bind open + inner + bound + bind close
            2 + inner.flattenedEntryCount + bound.flattenedEntryCount
        case let .resize(_, choices):
            // group open + choices + group close
            2 + choices.reduce(0) { $0 + $1.flattenedEntryCount }
        case let .selected(tree):
            tree.flattenedEntryCount
        }
    }

    /// Whether this node is a `.choice` leaf.
    var isChoice: Bool {
        if case .choice = self {
            return true
        }
        return false
    }

    /// Whether this node is a `.selected` wrapper.
    var isSelected: Bool {
        if case .selected = self {
            return true
        }
        return false
    }

    /// Whether this node is a `.branch` pick site.
    var isBranch: Bool {
        if case .branch = self {
            return true
        }
        return false
    }

    /// Whether this node is a `.just` constant.
    var isJust: Bool {
        if case .just = self {
            return true
        }
        return false
    }

    /// Whether this tree contains any data-dependent `.bind` nodes.
    ///
    /// Binds whose inner tree is `.getSize` are structurally stable (the size parameter is fixed during reduction) and are excluded.
    var containsBind: Bool {
        switch self {
        case let .bind(inner, bound):
            if inner.isGetSize {
                return bound.containsBind
            }
            return true
        case .choice, .just, .getSize:
            return false
        case let .branch(_, _, _, _, choice):
            return choice.containsBind
        case let .selected(inner):
            return inner.containsBind
        case let .sequence(_, elements, _):
            return elements.contains(where: \.containsBind)
        case let .group(array, _):
            return array.contains(where: \.containsBind)
        case let .resize(_, choices):
            return choices.contains(where: \.containsBind)
        }
    }

    /// Whether this node is a `.getSize` leaf.
    var isGetSize: Bool {
        if case .getSize = self {
            return true
        }
        return false
    }

    /// The site identifier with the depth contribution masked out, or `nil` if this node is not a `.branch`.
    ///
    /// Mirrors ``ChoiceSequenceValue/Branch/depthMaskedSiteID``. Strips the last three decimal digits from the site ID to recover a stable identifier shared across all depths of the same recursive generator.
    var depthMaskedSiteID: UInt64? {
        guard case let .branch(siteID, _, _, _, _) = self else { return nil }
        return siteID / 1000
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
        case let .group(array, _):
            array.contains(where: \.containsPicks)
        case let .bind(inner, bound):
            inner.containsPicks || bound.containsPicks
        case let .resize(_, choices):
            choices.contains(where: \.containsPicks)
        }
    }

    /// Returns the maximum `breadth × 2^pickDepth` across all pick sites, where pickDepth counts nested `.branch` levels.
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
        case let .group(array, _):
            return array.map { $0.pickComplexityHelper(pickDepth: pickDepth) }.max() ?? 0
        case let .bind(inner, bound):
            let innerComplexity = inner.pickComplexityHelper(pickDepth: pickDepth)
            let boundComplexity = bound.pickComplexityHelper(pickDepth: pickDepth)
            return max(innerComplexity, boundComplexity)
        case let .resize(_, choices):
            return choices.map { $0.pickComplexityHelper(pickDepth: pickDepth) }.max() ?? 0
        }
    }
}

public extension ChoiceTree {
    /// Recursively transforms a ``ChoiceTree`` by applying a given closure to each node.
    ///
    /// - Parameter transform: A closure that takes a ``ChoiceTree`` and returns a transformed ``ChoiceTree``.
    /// - Returns: A new ``ChoiceTree`` with the transform applied to all its nodes and their children.
    func map(_ transform: (ChoiceTree) throws -> ChoiceTree) rethrows -> ChoiceTree {
        let transformedNode = try transform(self)

        switch transformedNode {
        case .choice, .just, .getSize:
            // For leaf nodes, return the transformed node directly.
            return transformedNode
        case let .sequence(length, elements, metadata):
            // For a sequence, recursively map over its elements.
            let mapped = try elements.map { try $0.map(transform) }
            return try .sequence(
                length: length,
                elements: mapped,
                metadata
            )
        case let .branch(siteID, weight, id, branchIDs, choice):
            // For a branch, recursively map over its children.
            return try .branch(
                siteID: siteID,
                weight: weight,
                id: id,
                branchIDs: branchIDs,
                choice: choice.map(transform)
            )
        case let .group(children, isOpaque: isOpaque):
            // For a group, recursively map over its children.
            return try .group(children.map { try $0.map(transform) }, isOpaque: isOpaque)
        case let .bind(inner, bound):
            return try .bind(inner: inner.map(transform), bound: bound.map(transform))
        case let .selected(child):
            // For a selected node, recursively map over the locked child.
            return try .selected(child.map(transform))
        case let .resize(newSize, choices):
            // For a resize node, recursively map over its choices.
            return try .resize(newSize: newSize, choices: choices.map { try $0.map(transform) })
        }
    }

    /// Widens non-explicit sequence length ranges to accept any length.
    ///
    /// After structural passes like `deleteSequenceBoundaries` merge inner sequences, the tree's recorded length ranges can become stale. This method relaxes those ranges so subsequent materialization passes don't reject valid candidates.
    /// Only affects sequence nodes whose `isRangeExplicit` is `false`.
    func relaxingNonExplicitSequenceLengthRanges() -> ChoiceTree {
        map { node in
            guard case let .sequence(length, elements, metadata) = node,
                  metadata.isRangeExplicit == false
            else {
                return node
            }
            return .sequence(
                length: length,
                elements: elements,
                ChoiceMetadata(validRange: 0 ... UInt64.max, isRangeExplicit: false)
            )
        }
    }

    /// Returns whether any node in this tree satisfies the given predicate. Short-circuits on the first match.
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
        case let .sequence(_, elements, _), let .group(elements, _):
            // For a sequence, recursively map over its elements.
            return elements.contains { $0.contains(predicate) }
        case let .bind(inner, bound):
            return inner.contains(predicate) || bound.contains(predicate)
        case let .selected(child):
            // For a locked node, recursively map over the locked child.
            return child.contains(predicate)
        case let .resize(_, choices):
            return choices.contains { $0.contains(predicate) }
        }
    }
}

extension ChoiceTree: CustomDebugStringConvertible {
    public var prettyPrint: NSString {
        NSString(string: debugDescription)
    }

    public var debugDescription: String {
        treeDescription(prefix: "", isLast: true)
    }

    private func treeDescription(prefix: String, isLast: Bool, isSelected: Bool = false) -> String {
        let connector = isLast ? "└── " : "├── "
        let childPrefix = prefix + (isLast ? "    " : "│   ")
        let selected = isSelected ? "✅" : ""

        switch self {
        case let .choice(value, meta):
            let displayRange = value.displayRange(meta.validRange!)
            switch value {
            case let .unsigned(uint, _):
                return prefix + connector + "choice(unsigned:\(uint)) \(displayRange)"
            case let .signed(int, _, _):
                return prefix + connector + "choice(signed: \(int)) \(displayRange)"
            case let .floating(float, _, _):
                return prefix + connector + "choice(float: \(float)) \(displayRange)"
            }

        case .just:
            return prefix + connector + "just"

        case let .sequence(length, elements, meta):
            var result = prefix + connector + "sequence(length: \(length)) \(meta.validRange)"
            for (index, element) in elements.enumerated() {
                let isLastElement = index == elements.count - 1
                result += "\n" + element.treeDescription(prefix: childPrefix, isLast: isLastElement)
            }
            return result

        case let .branch(siteId, weight, id, branchIDs, gen):
            let index = branchIDs.firstIndex(of: id).map { $0 + 1 } ?? 0
            let fingerprintShort = String(format: "%08X", siteId & 0xFFFF_FFFF)
            var result = prefix + connector + "\(selected)branch(siteId: \(fingerprintShort), id: \(id), index: \(index), weight: \(weight), count: \(branchIDs.count))"
            result += "\n" + gen.treeDescription(prefix: childPrefix, isLast: true)
            return result

        case let .group(children, _):
            var result = prefix + connector + "group"
            for (index, child) in children.enumerated() {
                let isLastChild = index == children.count - 1
                result += "\n" + child.treeDescription(prefix: childPrefix, isLast: isLastChild)
            }
            return result

        case let .bind(inner, bound):
            var result = prefix + connector + "bind"
            result += "\n" + inner.treeDescription(prefix: childPrefix, isLast: false)
            result += "\n" + bound.treeDescription(prefix: childPrefix, isLast: true)
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

    public var elementDescription: String {
        switch self {
        case let .choice(choiceValue, _):
            switch choiceValue {
            case let .unsigned(uInt64, _):
                uInt64.description
            case let .signed(int, _, _):
                int.description
            case let .floating(float, _, _):
                float.description
            }
        case .just:
            "just"
        case let .sequence(_, elements, _):
            "[" + elements.map(\.elementDescription).joined(separator: ", ") + "]"
        case let .branch(_, weight, id, _, gen):
            "\(weight),\(id): \(gen.elementDescription)"
        case let .group(array, _):
            "{" + array.map(\.elementDescription).joined() + "}"
        case let .bind(inner, bound):
            "{" + inner.elementDescription + bound.elementDescription + "}"
        case let .selected(choiceTree):
            choiceTree.elementDescription
        case let .getSize(size):
            "getSize(\(size))"
        case let .resize(newSize, choices):
            "resize(\(newSize): [\(choices.map(\.elementDescription).joined(separator: ", "))])"
        }
    }

    /// Recursively unwraps `.selected` wrapper nodes to get the core content.
    public var unwrapped: ChoiceTree {
        switch self {
        case let .selected(inner):
            inner.unwrapped
        default:
            self
        }
    }

    public var branchId: UInt64? {
        if case let .branch(_, _, id, _, _) = unwrapped {
            return id
        }
        return nil
    }
}
