//
//  ChoiceTree.swift
//  Exhaust
//
//  Created by Chris Kolbu on 16/7/2025.
//

import Algorithms
import Foundation

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
    indirect case branch(label: UInt64, children: [ChoiceTree])
    
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
    var isSizing: Bool {
        switch self {
        case .getSize, .resize:
            return true
        default:
            return false
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
        case .getSize:
            return 1
        case .resize(_, let choices):
            return 2 + choices.map(\.structuralComplexity).reduce(0, +)
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
        case let .getSize(size):
            return size
        case .resize(_, let choices):
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

// Functor
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
        case let .sequence(_, elements, _), let .branch(_, elements), let .group(elements):
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
                
            // If both are resize, merge their choices recursively.
            case let (.resize(lhsSize, lhsChoices), .resize(_, rhsChoices)):
                if let containerResult = combine(self, other) {
                    return containerResult
                }
                let mergedChoices = zip(lhsChoices, rhsChoices).map { (lhsChoice, rhsChoice) in
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
        self.merge(with: other) {
            lhs,
            rhs in
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
                    lMeta
                )
                return transform(newLhs, rhs)
            case let (.group(lhs), .group(rhs)):
                let transformedGroup = zip(lhs, rhs).map { lhs, rhs in
                    lhs.mapWhereDifferent(to: rhs, using: transform)
                }
                let newLhs = ChoiceTree.group(transformedGroup)
                return newLhs
            default:
                return nil
            }
        }
    }
    
    /// Locks in values of `new` where there is a difference from `old`
    static func diffAndLockChanges(in new: ChoiceTree, from valid: ChoiceTree, keepStrategies: Bool, markImportant: Bool) -> ChoiceTree {
        new.merge(with: valid) { lhs, rhs in
            switch (lhs, rhs) {
            case let (.important(lhsValue), .important(rhsValue)):
                // Stop here
                return Self.diffAndLockChanges(in: lhsValue, from: rhsValue, keepStrategies: keepStrategies, markImportant: true)
            case (.important, _):
                return lhs
            case let (.choice(lhsValue, _), .choice(rhsValue, rhsMeta)):
                guard lhsValue != rhsValue else {
                    return lhs
                }
                // TODO: Decorate with whether we need to go down or up
                // 45_000 vs 0, so 0 triggered that this is important
                // We need to build a range from rhs...lhs
                let newLhs: ChoiceTree
                // This is being compared with a value that succeeded
                if markImportant {
                    let lhsRange = lhsValue.convertible.bitPattern64
                    let rhsRange = rhsValue.convertible.bitPattern64
                    // This won't work for doubles...
                    let convertibleRange = min(lhsRange, rhsRange)...max(lhsRange, rhsRange)
                    let meta = ChoiceMetadata(validRanges: [convertibleRange], strategies: [])
                    newLhs = markImportant
                        ? ChoiceTree.important(.choice(lhsValue, meta))
                        : .choice(lhsValue, meta)
                } else {
                    // We're not updating the range when the shrink was successful?
                    newLhs = lhs
                }
                
                return keepStrategies
                    ? newLhs.resetStrategies(direction: lhsValue.shrinkingDirection(given: rhsValue)) // This will apply strategies based on the effective range
                    : newLhs.with(strategies: rhsMeta.strategies)
            case let (.sequence(lhsLength, lhsElements, lhsMeta), .sequence(rhsLength, rhsElements, rhsMeta)):
                // The sequence itself is important
                if lhsLength != rhsLength {
                    // TODO: Decorate with whether we need to go down or up
                    // We can now create a valid subrange for the length of this sequence
                    let newLhs: ChoiceTree
                    if markImportant {
                        let newRange = min(lhsLength, rhsLength)...max(lhsLength, rhsLength)
                        // We know that the range has to be between what what's allowable and what failed
                        let meta = ChoiceMetadata(validRanges: [newRange], strategies: [])
                        newLhs = ChoiceTree.important(.sequence(length: lhsLength, elements: lhsElements, meta))
                    } else {
                        newLhs = lhs
                    }
                    return keepStrategies
                        ? newLhs.resetStrategies(direction: ChoiceValue(lhsLength).shrinkingDirection(given: ChoiceValue(rhsLength))) // This will apply strategies based on the effective range
                        : newLhs.with(strategies: rhsMeta.strategies)
                }
                // The sequence content is important
                if lhsElements.elementsEqual(rhsElements) == false {
                    let importantElements = zip(lhsElements, rhsElements).map { lhs, rhs in
                        ChoiceTree.diffAndLockChanges(in: lhs, from: rhs, keepStrategies: keepStrategies, markImportant: markImportant)
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
            case let .unsigned(uint):
                return prefix + connector + "\(locked)choice(unsigned:\(uint))\(locked) \(displayRange)"
            case let .signed(int, _, _):
                return prefix + connector + "\(locked)choice(signed: \(int))\(locked) \(displayRange))"
            case let .floating(float, _, _):
                return prefix + connector + "\(locked)choice(float: \(float))\(locked) \(displayRange)"
            }
            
        case .just(let type):
            return prefix + connector + "just(\(type))"
            
        case let .sequence(length, elements, meta):
            var result = prefix + connector + "\(locked)sequence(length: \(length))\(locked) \(meta.validRanges[0])"
            if
                case let .group(array) = elements.first,
                // Dropping the first one as it is a getSize
                case let .group(branches) = array.dropFirst().first,
                case let .branch(_, children) = branches.first(where: { $0.isSelected == false }),
                case .choice(.character(_), _) = children.first
            {
                // A special case displaying all the characters in a string inline
                let characters = elements.dropFirst().compactMap { element in
                    if
                        case let .group(array) = element,
                        case let .group(branches) = array.dropFirst().first,
                        // Why are we getting a nonselected branch?
                        // FIXME: The assumption that the character value of all branches is identical no longer holds with the Value|ChoiceTree generator, and this special case is broken because reflected generators come back as all being selected now :|
                        case let .branch(_, children) = branches.first(where: { $0.isSelected == false }),
                        case let .choice(.character(char), _) = children.first
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
        case .getSize:
            return prefix + connector + "getSize(?)"
        case let .resize(newSize, choices):
            var result = prefix + connector + "resize(?)"
            for (index, choice) in choices.enumerated() {
                let isLastChoice = index == choices.count - 1
                result += "\n" + choice.treeDescription(prefix: childPrefix, isLast: isLastChoice)
            }
            return result
        }
    }
    
    var elementDescription: String {
        switch self {
        case .choice(let choiceValue, _):
            switch choiceValue {
            case .unsigned(let uInt64):
                return uInt64.description
            case .signed(let int, _, _):
                return int.description
            case .floating(let float, _, _):
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
        case let .getSize(size):
            return "getSize(\(size))"
        case let .resize(newSize, choices):
            return "resize(\(newSize): [\(choices.map(\.elementDescription).joined(separator: ", "))])"
        }
    }
    
    var combinatoryComplexity: Double {
        switch self {
        case .choice(let choiceValue, let choiceMetadata):
            return choiceValue.combinatoryComplexity(for: choiceMetadata.validRanges[0])
        case .just:
            return 0
        case .sequence(_, let elements, let choiceMetadata):
            let range = choiceMetadata.validRanges[0].cast(type: Int64.self)
            if range.lowerBound == .min || range.upperBound == .max {
                return Double(Int64.max)
            }
            return Double(range.upperBound - range.lowerBound) + elements.reduce(0, { $0 + $1.combinatoryComplexity })
        case .branch(_, let children):
            return children.reduce(0, { $0 + $1.combinatoryComplexity })
        case .group(let array):
            return array.reduce(0, { $0 + $1.combinatoryComplexity })
        case .getSize:
            return 0
        case .resize(_, let choices):
            return choices.reduce(0, { $0 + $1.combinatoryComplexity })
        case .important(let choiceTree):
            return choiceTree.combinatoryComplexity
        case .selected(let choiceTree):
            return choiceTree.combinatoryComplexity
        }
    }
    
    // Defined as distance from zero for ranges that contain zero, or distance from the midpoint of the range?
    var valueComplexity: Double {
        switch self {
        case .choice(let choiceValue, let meta):
            switch choiceValue {
            case .unsigned(let uInt64):
                let range = meta.validRanges[0]
                if range.contains(0) {
                    return Double(uInt64)
                } else {
                    return Double(range.midPoint)
                }
            case .signed(let int64, _, _):
                let range = meta.validRanges[0]
                let zero = Int64(0).bitPattern64
                if range.contains(zero) {
                    return Double(abs(int64))
                }
                return Double(Int64(bitPattern64: range.midPoint))
            case .floating(let double, _, _):
                let range = meta.validRanges[0]
                let zero = Double(0).bitPattern64
                if range.contains(zero) {
                    return abs(double)
                }
                return Double(bitPattern64: range.midPoint)
            case .character(let character):
                let range = meta.validRanges[0]
                if range.contains(0) {
                    return Double(character.bitPattern64)
                } else {
                    return Double(range.midPoint)
                }
            }
        case .just:
            return 0
        case .sequence(let length, let elements, _):
            return elements.reduce(into: Double(0)) { $0 += $1.valueComplexity }
        case .branch(let label, let children):
            return children.reduce(into: Double(0)) { $0 += $1.valueComplexity }
        case .group(let array):
            return array.reduce(into: Double(0)) { $0 += $1.valueComplexity }
        case .getSize:
            return 0
        case .resize(_, let choices):
            return choices.reduce(into: Double(0)) { $0 += $1.valueComplexity }
        case .important(let choiceTree):
            return choiceTree.valueComplexity
        case .selected(let choiceTree):
            return choiceTree.valueComplexity
        }
    }
    
    func flattenForClassification(prefix: String = "", depth: Int = 0) -> [(label: String, type: String, value: String)] {
        switch self {
        case .choice(let choiceValue, let choiceMetadata):
            let label = "choice\(prefix.isEmpty ? "" : "_b\(prefix)")_d\(depth)"
            let type = "continuous"
            switch choiceValue {
            case .unsigned(let uInt64):
                return [(label, type, uInt64.description)]
            case .signed(let int64, _, _):
                return [(label, type, int64.description)]
            case .floating(let double, _, _):
                return [(label, type, double.description)]
            case .character(let character):
                fatalError("This should have been caught by .sequence")
            }
        case .just(let string):
            return [("just\(prefix.isEmpty ? "" : "_b\(prefix)")_d\(depth)", "discrete", string)] // No point shrinking on this
        case .sequence(let length, let elements, let choiceMetadata):
            var features: [(label: String, type: String, value: String)] = []
            let seqPrefix = "sequence\(prefix.isEmpty ? "" : "_b\(prefix)")_d\(depth)"
            
            // Basic length feature
            features.append((seqPrefix + "_length", "continuous", length.description))
            
            // Analyze element types and values
            if !elements.isEmpty {
                let elementTypes = elements.map { element -> String in
                    switch element {
                    case .choice(let value, _):
                        switch value {
                        case .unsigned, .signed: return "int"
                        case .floating: return "float" 
                        case .character: return "char"
                        }
                    case .just: return "const"
                    default: return "complex"
                    }
                }
                
                // Element type distribution
//                let uniqueTypes = Set(elementTypes)
//                features.append((seqPrefix + "_types", "discrete", uniqueTypes.sorted().joined(separator: ",")))
//                features.append((seqPrefix + "_type_count", "continuous", uniqueTypes.count.description))
                
//                // First and last element features (if simple values)
//                if let firstElement = elements.first,
//                   case .choice(let firstValue, _) = firstElement {
//                    features.append((seqPrefix + "_first", "continuous", String(describing: firstValue.convertible)))
//                }
//                
//                if let lastElement = elements.last,
//                   case .choice(let lastValue, _) = lastElement {
//                    features.append((seqPrefix + "_last", "continuous", String(describing: lastValue.convertible)))
//                }
                
                // Extract numeric values for statistical analysis
                let numericValues = elements.compactMap { element -> Double? in
                    guard case .choice(let value, _) = element else { return nil }
                    return value.doubleValue
                }
                
                if !numericValues.isEmpty {
                    let sum = numericValues.reduce(0, +)
                    let mean = sum / Double(numericValues.count)
                    let minVal = numericValues.min() ?? 0
                    let maxVal = numericValues.max() ?? 0
                    
                    features.append((seqPrefix + "_mean", "continuous", String(format: "%.3f", mean)))
                    features.append((seqPrefix + "_min", "continuous", minVal.description))
                    features.append((seqPrefix + "_max", "continuous", maxVal.description))
                    features.append((seqPrefix + "_range", "continuous", (maxVal - minVal).description))
                    
                    // Check for patterns
//                    let isAscending = numericValues.enumerated().dropFirst().allSatisfy { $1 >= numericValues[$0.offset - 1] }
//                    let isDescending = numericValues.enumerated().dropFirst().allSatisfy { $1 <= numericValues[$0.offset - 1] }
//                    
//                    if isAscending && !isDescending {
//                        features.append((seqPrefix + "_pattern", "discrete", "ascending"))
//                    } else if isDescending && !isAscending {
//                        features.append((seqPrefix + "_pattern", "discrete", "descending"))
//                    } else {
//                        features.append((seqPrefix + "_pattern", "discrete", "mixed"))
//                    }
                }
            }
            
            return features
        case .branch(let label, let children):
            // If the branches all return .just shoul
            return children.flatMap { child in
                // Only return selected branches
                // FIXME: What if a generator has two valid selected branches?
//                guard case .selected = child else {
//                    return [(label: String, type: String, value: String)]()
//                }
                return child.flattenForClassification(prefix: label.description, depth: depth + 1)
            }
        case .group(let array):
            if self.isPickOfJusts {
                // We can return a discrete type representing all the possible values here?
                let results = array.map { ($0.isSelected, $0.flattenForClassification(depth: depth + 1)) }
                let values = results.flatMap(\.1).map(\.value)
                let currentValue = results.filter(\.0).flatMap(\.1).firstNonNil(\.value)
                // Set value to the one that is selected?
                return [("pick\(prefix.isEmpty ? "" : "_b\(prefix)")_d\(depth)", values.joined(separator: ","), currentValue ?? "?")]
            } else {
                return array.flatMap { $0.flattenForClassification(depth: depth + 1) }
            }
        case .getSize(let uInt64):
            return []
        case .resize(_, let choices):
            return choices.flatMap { $0.flattenForClassification(depth: depth + 1) }
        case .important(let choiceTree), .selected(let choiceTree):
            return choiceTree.flattenForClassification(depth: depth) // Keep depth the same
        }
    }
    
    var isPickOfJusts: Bool {
        guard case let .group(array) = self else {
            return false
        }
        // Now, does this array represent a series of branches containing justs?
        guard
            array.contains(where: { $0.isBranch }),
            // This may fail if the branches are all resized
            array.allSatisfy({ $0.isBranch || $0.isSelected || $0.isSizing })
        else {
            return false
        }
        return true
    }
}

//extension ChoiceTree: Comparable {
//    static func < (lhs: ChoiceTree, rhs: ChoiceTree) -> Bool {
//        switch lhs {
////        case .choice(let choiceValue, let choiceMetadata):
////            <#code#>
////        case .just(let string):
////            <#code#>
////        case .sequence(let length, let elements, let choiceMetadata):
////            <#code#>
////        case .branch(let label, let children):
////            <#code#>
////        case .group(let array):
////            <#code#>
////        case .getSize(let uInt64):
////            <#code#>
////        case .resize(let newSize, let choices):
////            <#code#>
////        case .important(let choiceTree):
////            <#code#>
////        case .selected(let choiceTree):
////            <#code#>
////        }
//        switch (lhs, rhs) {
//        case let (.choice(lhsV, _), .choice(rhsV, _)):
//            return lhsV < rhsV
//        
//        }
//    }
//    
//    
//}

extension ClosedRange where Bound == UInt64 {
    var midPoint: UInt64 {
        let span = upperBound - lowerBound
        return lowerBound + (span / 2)
    }
}
