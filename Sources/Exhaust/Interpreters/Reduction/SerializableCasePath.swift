//
//  SerializableCasePath.swift
//  Exhaust
//
//  Created by Chris Kolbu on 8/8/2025.
//

import Foundation

/// A serializable case path that maintains bidirectional mapping between ChoiceTree structures and classifier rules
public struct SerializableCasePath<Root, Value>: Sendable {
    public let serializedPath: String
    private let extractor: @Sendable (Root) -> Value?
    private let applicator: @Sendable (Root, Value) -> Root?
    
    public init(
        serializedPath: String,
        extractor: @escaping @Sendable (Root) -> Value?,
        applicator: @escaping @Sendable (Root, Value) -> Root?
    ) {
        self.serializedPath = serializedPath
        self.extractor = extractor
        self.applicator = applicator
    }
    
    /// Extract a value from the root using this path
    public func extract(from root: Root) -> Value? {
        return extractor(root)
    }
    
    /// Apply a value to the root using this path, returning modified root
    public func apply(value: Value, to root: Root) -> Root? {
        return applicator(root, value)
    }
}

/// Canonical paths for ChoiceTree navigation and modification
public enum ChoiceTreeCasePaths {
    /// Path to choice value in a choice node
    public static let choiceValue = SerializableCasePath<ChoiceTree, ChoiceValue>(
        serializedPath: "choice.value",
        extractor: { tree in
            if case let .choice(value, _) = tree {
                return value
            }
            return nil
        },
        applicator: { tree, newValue in
            if case let .choice(_, metadata) = tree {
                return .choice(newValue, metadata)
            }
            return nil
        }
    )
    
    /// Path to sequence length
    public static let sequenceLength = SerializableCasePath<ChoiceTree, UInt64>(
        serializedPath: "sequence.length",
        extractor: { tree in
            if case let .sequence(length, _, _) = tree {
                return length
            }
            return nil
        },
        applicator: { tree, newLength in
            if case let .sequence(_, elements, metadata) = tree {
                return .sequence(length: newLength, elements: elements, metadata)
            }
            return nil
        }
    )
    
    /// Path to sequence elements
    public static let sequenceElements = SerializableCasePath<ChoiceTree, [ChoiceTree]>(
        serializedPath: "sequence.elements",
        extractor: { tree in
            if case let .sequence(_, elements, _) = tree {
                return elements
            }
            return nil
        },
        applicator: { tree, newElements in
            if case let .sequence(length, _, metadata) = tree {
                return .sequence(length: length, elements: newElements, metadata)
            }
            return nil
        }
    )
    
    /// Path to branch children
    public static let branchChildren = SerializableCasePath<ChoiceTree, [ChoiceTree]>(
        serializedPath: "branch.children",
        extractor: { tree in
            if case let .branch(_, children) = tree {
                return children
            }
            return nil
        },
        applicator: { tree, newChildren in
            if case let .branch(label, _) = tree {
                return .branch(label: label, children: newChildren)
            }
            return nil
        }
    )
    
    /// Path to group children
    public static let groupChildren = SerializableCasePath<ChoiceTree, [ChoiceTree]>(
        serializedPath: "group.children",
        extractor: { tree in
            if case let .group(children) = tree {
                return children
            }
            return nil
        },
        applicator: { tree, newChildren in
            if case .group = tree {
                return .group(newChildren)
            }
            return nil
        }
    )
    
    /// Path to important inner value
    public static let importantInner = SerializableCasePath<ChoiceTree, ChoiceTree>(
        serializedPath: "important.inner",
        extractor: { tree in
            if case let .important(inner) = tree {
                return inner
            }
            return nil
        },
        applicator: { tree, newInner in
            if case .important = tree {
                return .important(newInner)
            }
            return nil
        }
    )
    
    /// Path to selected inner value  
    public static let selectedInner = SerializableCasePath<ChoiceTree, ChoiceTree>(
        serializedPath: "selected.inner",
        extractor: { tree in
            if case let .selected(inner) = tree {
                return inner
            }
            return nil
        },
        applicator: { tree, newInner in
            if case .selected = tree {
                return .selected(newInner)
            }
            return nil
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
    public static func casePath<T>(for serializedPath: String) -> SerializableCasePath<ChoiceTree, T>? {
        return pathMap[serializedPath] as? SerializableCasePath<ChoiceTree, T>
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