//
//  ChoiceTreeCasePaths.swift
//  Exhaust
//
//  Created by Chris Kolbu on 8/8/2025.
//

import Foundation
import CasePaths

/// A wrapper around CasePath that includes serialization information for classifier integration
public struct SerializableChoiceTreePath<Value>: Sendable {
    public let serializedPath: String
    public let extract: @Sendable (ChoiceTree) -> Value?
    public let apply: @Sendable (Value, ChoiceTree) -> ChoiceTree?
    
    public init(
        serializedPath: String,
        extract: @escaping @Sendable (ChoiceTree) -> Value?,
        apply: @escaping @Sendable (Value, ChoiceTree) -> ChoiceTree?
    ) {
        self.serializedPath = serializedPath
        self.extract = extract
        self.apply = apply
    }
    
    /// Extract a value from the tree using this path
    public func extract(from tree: ChoiceTree) -> Value? {
        return extract(tree)
    }
    
    /// Apply a value to the tree using this path, returning modified tree
    public func apply(value: Value, to tree: ChoiceTree) -> ChoiceTree? {
        return apply(value, tree)
    }
}

/// Canonical paths for ChoiceTree navigation and modification using Swift Case Paths
public enum ChoiceTreeCasePaths {
    /// Path to choice value in a choice node (first tuple element)
    public static let choiceValue = SerializableChoiceTreePath<ChoiceValue>(
        serializedPath: "choice.value",
        extract: { tree in
            tree[case: \ChoiceTree.Cases.choice]?.0
        },
        apply: { newValue, tree in
            guard let (_, metadata) = tree[case: \ChoiceTree.Cases.choice] else { return nil }
            return .choice(newValue, metadata)
        }
    )
    
    /// Path to sequence length (named parameter)
    public static let sequenceLength = SerializableChoiceTreePath<UInt64>(
        serializedPath: "sequence.length", 
        extract: { tree in
            tree[case: \ChoiceTree.Cases.sequence]?.0
        },
        apply: { newLength, tree in
            guard let (_, elements, metadata) = tree[case: \ChoiceTree.Cases.sequence] else { return nil }
            return .sequence(length: newLength, elements: elements, metadata)
        }
    )
    
    /// Path to sequence elements (named parameter)
    public static let sequenceElements = SerializableChoiceTreePath<[ChoiceTree]>(
        serializedPath: "sequence.elements",
        extract: { tree in
            tree[case: \ChoiceTree.Cases.sequence]?.1
        },
        apply: { newElements, tree in
            guard let (length, _, metadata) = tree[case: \ChoiceTree.Cases.sequence] else { return nil }
            return .sequence(length: length, elements: newElements, metadata)
        }
    )
    
    /// Path to branch children (named parameter)
    public static let branchChildren = SerializableChoiceTreePath<[ChoiceTree]>(
        serializedPath: "branch.children",
        extract: { tree in
            tree[case: \ChoiceTree.Cases.branch]?.1
        },
        apply: { newChildren, tree in
            guard let (label, _) = tree[case: \ChoiceTree.Cases.branch] else { return nil }
            return .branch(label: label, children: newChildren)
        }
    )
    
    /// Path to group children (the array itself)
    public static let groupChildren = SerializableChoiceTreePath<[ChoiceTree]>(
        serializedPath: "group.children",
        extract: { tree in
            tree[case: \ChoiceTree.Cases.group]
        },
        apply: { newChildren, _ in
            .group(newChildren)
        }
    )
    
    /// Path to important inner value
    public static let importantInner = SerializableChoiceTreePath<ChoiceTree>(
        serializedPath: "important.inner",
        extract: { tree in
            tree[case: \ChoiceTree.Cases.important]
        },
        apply: { newInner, _ in
            .important(newInner)
        }
    )
    
    /// Path to selected inner value  
    public static let selectedInner = SerializableChoiceTreePath<ChoiceTree>(
        serializedPath: "selected.inner",
        extract: { tree in
            tree[case: \ChoiceTree.Cases.selected]
        },
        apply: { newInner, _ in
            .selected(newInner)
        }
    )
}

/// Registry mapping serialized paths to their corresponding case paths
public struct CasePathRegistry {
    @MainActor
    private static let pathMap: [String: Any] = [
        "choice.value": ChoiceTreeCasePaths.choiceValue,
        "sequence.length": ChoiceTreeCasePaths.sequenceLength,
        "sequence.elements": ChoiceTreeCasePaths.sequenceElements,
        "branch.children": ChoiceTreeCasePaths.branchChildren,
        "group.children": ChoiceTreeCasePaths.groupChildren,
        "important.inner": ChoiceTreeCasePaths.importantInner,
        "selected.inner": ChoiceTreeCasePaths.selectedInner
    ]
    
    /// Retrieve a case path by its serialized representation
    @MainActor
    public static func casePath<T>(for serializedPath: String) -> SerializableChoiceTreePath<T>? {
        return pathMap[serializedPath] as? SerializableChoiceTreePath<T>
    }
    
    /// Get all available serialized paths
    @MainActor
    public static var availablePaths: [String] {
        return Array(pathMap.keys)
    }
}

/// Represents a transformation rule derived from decision tree classification
public struct TreeTransformationRule: Sendable {
    public let path: String
    public let condition: RuleCondition  
    public let transformation: RuleTransformation
    public let confidence: Double
    
    public init(path: String, condition: RuleCondition, transformation: RuleTransformation, confidence: Double) {
        self.path = path
        self.condition = condition
        self.transformation = transformation
        self.confidence = confidence
    }
}

/// Condition for applying a transformation rule
public enum RuleCondition: Sendable {
    case lessThan(Double)
    case greaterThan(Double)
    case equalTo(String)
    case between(Double, Double)
    case contains(String)
}

/// Transformation to apply when rule condition is met
public enum RuleTransformation: Sendable {
    case setValue(any Sendable)
    case multiplyBy(Double)
    case addOffset(Double)
    case reduceTo(Int)
    case applyStrategy(ClassificationStrategy)
}

extension RuleCondition {
    /// Check if a value satisfies this condition
    public func matches<T>(_ value: T) -> Bool {
        switch self {
        case let .lessThan(threshold):
            if let doubleValue = value as? Double {
                return doubleValue < threshold
            }
            return false
            
        case let .greaterThan(threshold):
            if let doubleValue = value as? Double {
                return doubleValue > threshold
            }
            return false
            
        case let .equalTo(expected):
            return String(describing: value) == expected
            
        case let .between(lower, upper):
            if let doubleValue = value as? Double {
                return doubleValue >= lower && doubleValue <= upper
            }
            return false
            
        case let .contains(substring):
            return String(describing: value).contains(substring)
        }
    }
}