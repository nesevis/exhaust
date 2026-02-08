//
//  ChoiceTreeCasePaths.swift
//  Exhaust
//
//  Created by Chris Kolbu on 8/8/2025.
//

import Foundation
import CasePaths
import See5

/// A wrapper around CasePath that includes serialization information for classifier integration
public struct SerializableChoiceTreePath<Value>: Sendable, Hashable {
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
    
    public static func == (lhs: SerializableChoiceTreePath<Value>, rhs: SerializableChoiceTreePath<Value>) -> Bool {
        lhs.hashValue == rhs.hashValue
    }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(serializedPath)
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
    public static let branchChildren = SerializableChoiceTreePath<ChoiceTree>(
        serializedPath: "branch.children",
        extract: { tree in
            tree[case: \ChoiceTree.Cases.branch]?.2
        },
        apply: { new, tree in
            guard let (weight, label, _) = tree[case: \ChoiceTree.Cases.branch] else { return nil }
            return .branch(weight: weight, label: label, choice: new)
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

/// Dynamic schema generator for ChoiceTree classification
public struct DynamicChoiceTreeSchema {
    public let features: [FeatureDescriptor]
    
    public struct FeatureDescriptor: Sendable, Hashable {
        public let path: String
        public let name: String
        public let type: FeatureType
        public let extractor: SerializableChoiceTreePath<String>
        
        public enum FeatureType: String, Sendable {
            case continuous
            case discrete
        }
        
        public init(path: String, name: String, type: FeatureType) {
            self.path = path
            self.name = name
            self.type = type
            self.extractor = SerializableChoiceTreePath<String>(
                serializedPath: path,
                extract: Self.createExtractor(for: path),
                apply: { _, tree in tree } // Not used for classification
            )
        }
        
        static func createExtractor(for path: String) -> @Sendable (ChoiceTree) -> String? {
            return { tree in
                let components = path.split(separator: ".").map(String.init)
                return Self.extractValue(from: tree, components: components)
            }
        }
        
        private static func extractValue(from tree: ChoiceTree, components: [String]) -> String? {
            guard !components.isEmpty else { return nil }
            
            let first = components[0]
            let remaining = Array(components.dropFirst())
            
            switch (first, tree) {
            case ("choice", .choice(let value, _)):
                if remaining.isEmpty {
                    return String(describing: value.convertible)
                }
                return nil
                
            case ("sequence", .sequence(let length, let elements, _)):
                if remaining.isEmpty {
                    return length.description
                } else if remaining.first == "length" {
                    return length.description
                } else if remaining.first == "complexity" {
                    return String(format: "%.6f", calculateSequenceComplexity(elements))
                } else if remaining.first == "entropy" {
                    return String(format: "%.6f", calculateSequenceEntropy(elements))
                } else if remaining.first == "elements", remaining.count > 1 {
                    if let index = Int(remaining[1]), index < elements.count {
                        return extractValue(from: elements[index], components: Array(remaining.dropFirst(2)))
                    }
                }
                return nil
                
                
            case ("branch", let .branch(weight, label, gen)):
                if remaining.first == "label" {
                    return label.description
                } else if remaining.first == "children", remaining.count > 1 {
                    if let index = Int(remaining[1]), index < 1 {
                        return extractValue(from: gen, components: Array(remaining.dropFirst(2)))
                    }
                }
                return nil
                
            case ("group", .group(let children)):
                if remaining.first == "children", remaining.count > 1 {
                    if let index = Int(remaining[1]), index < children.count {
                        return extractValue(from: children[index], components: Array(remaining.dropFirst(2)))
                    }
                }
                return nil
                
            case ("important", .important(let inner)):
                return extractValue(from: inner, components: remaining)
                
            case ("selected", .selected(let inner)):
                return extractValue(from: inner, components: remaining)
                
            case ("pick", .group(let children)) where tree.isPickOfJusts:
                // Extract the selected value from a pick of just values
                for child in children {
                    // Check if this child is selected (could be wrapped)
                    if case .selected = child {
                        let unwrapped = child.unwrapped
                        if case .branch(_, _, let gen) = unwrapped,
                           case .just(let value) = gen {
                            return value
                        }
                    }
                }
                return nil
                
            default:
                return nil
            }
        }
    }
    
    /// Generate schema from a collection of ChoiceTree instances
    public static func generateSchema(from trees: [ChoiceTree]) -> DynamicChoiceTreeSchema {
        var allPaths = Set<String>()
        
        // Collect all possible paths from all trees
        for tree in trees {
            let paths = collectPaths(from: tree, prefix: "")
            allPaths.formUnion(paths)
        }
        
        // Convert paths to feature descriptors with deterministic ordering
        // Sort paths lexicographically for consistent field ordering
        let sortedPaths = allPaths.sorted { path1, path2 in
            // First sort by path components for logical grouping
            let components1 = path1.split(separator: ".").map(String.init)
            let components2 = path2.split(separator: ".").map(String.init)
            
            // Compare component by component for hierarchical ordering
            for (comp1, comp2) in zip(components1, components2) {
                if comp1 != comp2 {
                    // Handle numeric components specially for proper ordering
                    if let num1 = Int(comp1), let num2 = Int(comp2) {
                        return num1 < num2
                    }
                    return comp1 < comp2
                }
            }
            
            // Shorter paths come first if one is a prefix of another
            return components1.count < components2.count
        }
        
        let features = sortedPaths.map { path in
            let type = inferType(for: path, in: trees)
            let name = path.replacingOccurrences(of: ".", with: "_")
            return FeatureDescriptor(path: path, name: name, type: type)
        }
        
        return DynamicChoiceTreeSchema(features: features)
    }
    
    private static func collectPaths(from tree: ChoiceTree, prefix: String, depth: Int = 0) -> Set<String> {
        var paths = Set<String>()
        let currentPrefix = prefix.isEmpty ? "" : "\(prefix)."
        
        // Limit depth to prevent infinite recursion
        guard depth < 10 else { return paths }
        
        switch tree {
        case .choice:
            paths.insert("\(currentPrefix)choice")
            
        case .sequence(_, let elements, _):
            // Always include sequence metrics
            paths.insert("\(currentPrefix)sequence.length")
            paths.insert("\(currentPrefix)sequence.complexity")
            paths.insert("\(currentPrefix)sequence.entropy")
            
            // For non-character sequences, also include individual elements
            if !isCharacterSequence(elements) {
                for (index, element) in elements.enumerated() {
                    let elementPaths = collectPaths(from: element, prefix: "\(currentPrefix)sequence.elements.\(index)", depth: depth + 1)
                    paths.formUnion(elementPaths)
                }
            }
            
        case .branch(_, _, let gen):
            paths.insert("\(currentPrefix)branch.label")
            let childPaths = collectPaths(from: gen, prefix: "\(currentPrefix)branch.gen", depth: depth + 1)
            paths.formUnion(childPaths)
            
        case .group(let children):
            // Check if this is a pick of just values (like Bool.arbitrary)
            if tree.isPickOfJusts {
                paths.insert("\(currentPrefix)pick")
            } else {
                for (index, child) in children.enumerated() {
                    let childPaths = collectPaths(from: child, prefix: "\(currentPrefix)group.children.\(index)", depth: depth + 1)
                    paths.formUnion(childPaths)
                }
            }
            
        case .important(let inner):
            let innerPaths = collectPaths(from: inner, prefix: "\(currentPrefix)important", depth: depth)
            paths.formUnion(innerPaths)
            
        case .selected(let inner):
            let innerPaths = collectPaths(from: inner, prefix: "\(currentPrefix)selected", depth: depth)
            paths.formUnion(innerPaths)
            
        case .getSize, .just, .resize:
            // These don't contribute features for classification
            break
        }
        
        return paths
    }
    
    private static func inferType(for path: String, in trees: [ChoiceTree]) -> FeatureDescriptor.FeatureType {
        // Sequence metrics are always continuous
        if path.contains("sequence.length") || path.contains("sequence.complexity") || path.contains("sequence.entropy") {
            return .continuous
        }
        
        // Sample a few values to infer type
        let sampleValues = trees.prefix(10).compactMap { tree in
            FeatureDescriptor.createExtractor(for: path)(tree)
        }
        
        // If all values can be parsed as numbers, it's continuous
        let areNumeric = sampleValues.allSatisfy { value in
            Double(value) != nil
        }
        
        return areNumeric ? .continuous : .discrete
    }
    
    /// Extract a string from a sequence of character ChoiceTrees
    private static func extractStringFromSequence(_ elements: [ChoiceTree]) -> String {
        let characters = elements.compactMap { element -> Character? in
            let unwrapped = element.unwrapped
            switch unwrapped {
            case .choice(let value, _):
                if case .character(let char) = value {
                    return char
                }
            case .just(let string):
                return string.first
            default:
                break
            }
            return nil
        }
        return String(characters)
    }
    
    /// Determines if a sequence of ChoiceTrees represents a character sequence
    static func isCharacterSequence(_ elements: [ChoiceTree]) -> Bool {
        guard !elements.isEmpty else { return false }
        
        // Heuristic: If we have more than a reasonable number of elements for normal sequences,
        // and they look like single character values, treat as character sequence
        if elements.count > 10 {
            return true // Assume very long sequences are strings
        }
        
        // Check if most elements look like characters by examining deeply nested structures
        let characterLikeCount = elements.count { element in
            return containsCharacterChoice(element)
        }
        
        // If more than half the elements contain character choices, treat as character sequence
        return Double(characterLikeCount) / Double(elements.count) > 0.5
    }
    
    /// Recursively searches for character choices within nested tree structures
    private static func containsCharacterChoice(_ tree: ChoiceTree) -> Bool {
        switch tree {
        case .choice(let value, _):
            // Direct character choice
            if case .character = value {
                return true
            }
            // Small integers that could be character codes
            switch value {
            case .unsigned(let val) where val < 1114112: // Max Unicode codepoint
                return true
            default:
                return false
            }
        case .just(let string):
            // Single character strings are likely characters from character generators
            return string.count == 1
        case .branch(_, _, let gen):
            return containsCharacterChoice(gen)
        case .group(let children):
            // Recursively search in children
            return children.contains { containsCharacterChoice($0) }
        case .sequence:
            // Don't recurse into other sequences
            return false
        case .important(let inner), .selected(let inner):
            // Unwrap and continue searching
            return containsCharacterChoice(inner)
        case .getSize, .resize:
            return false
        }
    }
    
    /// Calculate sequence complexity (for strings, average Unicode value)
    private static func calculateSequenceComplexity(_ elements: [ChoiceTree]) -> Double {
        guard !elements.isEmpty else { return 0.0 }
        
        let values = elements.compactMap { element -> Double? in
            let unwrapped = element.unwrapped
            switch unwrapped {
            case .choice(let value, _):
                switch value {
                case .character(let char):
                    return Double(char.unicodeScalars.first?.value ?? 0)
                case .unsigned(let uint):
                    return Double(uint)
                case .signed(let int, _, _):
                    return Double(int)
                case .floating(let double, _, _):
                    return double
                }
            case .just(let string):
                // For single character strings, use the character's Unicode value
                if string.count == 1, let char = string.first {
                    return Double(char.unicodeScalars.first?.value ?? 0)
                }
                // For other strings, use length as a proxy
                return Double(string.count)
            default:
                return nil
            }
        }
        
        return values.isEmpty ? 0.0 : values.reduce(0, +) / Double(values.count)
    }
    
    /// Calculate sequence entropy using Shannon entropy
    private static func calculateSequenceEntropy(_ elements: [ChoiceTree]) -> Double {
        guard !elements.isEmpty else { return 0.0 }
        
        // Extract comparable values from elements
        let values = elements.compactMap { element -> String? in
            let unwrapped = element.unwrapped
            switch unwrapped {
            case .choice(let value, _):
                return String(describing: value.convertible)
            case .just(let string):
                return string
            default:
                return nil
            }
        }
        
        guard !values.isEmpty else { return 0.0 }
        
        // Count frequencies
        var frequencies: [String: Int] = [:]
        for value in values {
            frequencies[value, default: 0] += 1
        }
        
        let total = Double(values.count)
        var entropy = 0.0
        
        for count in frequencies.values {
            let probability = Double(count) / total
            if probability > 0 {
                entropy -= probability * log2(probability)
            }
        }
        
        return entropy
    }
    
    /// Extract features from a tree using this schema, returning "?" for missing values
    public func extractFeatures(from tree: ChoiceTree) -> [String] {
        return features.map { feature in
            feature.extractor.extract(from: tree) ?? "?"
        }
    }
    
    /// Create a labeled data case from a ChoiceTree with target class
    public func createLabeledCase(from tree: ChoiceTree, targetClass: String, weight: Double? = nil, caseID: String? = nil) -> LabeledDataCase {
        let featureValues = extractFeatures(from: tree)
        return LabeledDataCase(
            values: featureValues,
            targetClass: targetClass,
            weight: weight,
            caseID: caseID
        )
    }
    
    /// Create labeled data cases from multiple trees with their classifications
    public func createLabeledCases(from treesWithClasses: [(ChoiceTree, String)]) -> [LabeledDataCase] {
        return treesWithClasses.map { tree, targetClass in
            createLabeledCase(from: tree, targetClass: targetClass)
        }
    }
    
    /// Convert to See5 DataSchema
    public func toSee5DataSchema(classes: [String]) -> See5.DataSchema {
        let attributeDefinitions = features.map { feature in
            let attributeType: See5.AttributeType = switch feature.type {
            case .continuous:
                .continuous
            case .discrete:
                // For discrete types, we need to collect all possible values
                // Since we can't know all discrete values from the schema alone,
                // we'll treat unknowns as continuous for now
                .continuous
            }
            
            return See5.AttributeDefinition(
                name: feature.name,
                type: attributeType
            )
        }
        
        return See5.DataSchema(
            attributes: attributeDefinitions,
            classes: classes
        )
    }
    
    /// Convert to See5 DataSchema with discovered discrete values
    public func toSee5DataSchema(classes: [String], fromTrees trees: [ChoiceTree]) -> See5.DataSchema {
        let attributeDefinitions = features.map { feature in
            let attributeType: See5.AttributeType
            
            switch feature.type {
            case .continuous:
                attributeType = .continuous
            case .discrete:
                // Collect all possible values for this discrete feature with deterministic ordering
                let allValues = trees.compactMap { tree in
                    feature.extractor.extract(from: tree)
                }.filter { $0 != "?" }
                
                // Use array to preserve insertion order, then sort for deterministic results
                let uniqueValues = Array(Set(allValues)).sorted()
                
                if uniqueValues.isEmpty {
                    attributeType = .continuous  // Fallback if no values found
                } else {
                    attributeType = .discrete(values: uniqueValues)
                }
            }
            
            return See5.AttributeDefinition(
                name: feature.name,
                type: attributeType
            )
        }
        
        return See5.DataSchema(
            attributes: attributeDefinitions,
            classes: classes
        )
    }
    
    /// Create See5 labeled data case from a ChoiceTree
    public func createSee5LabeledCase(from tree: ChoiceTree, targetClass: String, weight: Double? = nil, caseID: String? = nil) -> See5.LabeledDataCase {
        let featureValues = extractFeatures(from: tree)
        
        let attributeValues: [See5.AttributeValue?] = zip(features, featureValues).map { feature, value in
            if value == "?" {
                return nil  // Missing value
            }
            
            switch feature.type {
            case .continuous:
                return .continuous(value)
            case .discrete:
                return .discrete(value)
            }
        }
        
        return See5.LabeledDataCase(
            values: attributeValues,
            targetClass: targetClass,
            weight: weight,
            caseID: caseID
        )
    }
    
    /// Create See5 labeled data cases from multiple trees
    public func createSee5LabeledCases(from treesWithClasses: [(ChoiceTree, String)]) -> [See5.LabeledDataCase] {
        return treesWithClasses.map { tree, targetClass in
            createSee5LabeledCase(from: tree, targetClass: targetClass)
        }
    }
}

/// Represents a labeled data case for classification (internal format)
public struct LabeledDataCase: Sendable {
    public let values: [String]
    public let targetClass: String
    public let weight: Double?
    public let caseID: String?
    
    public init(values: [String], targetClass: String, weight: Double? = nil, caseID: String? = nil) {
        self.values = values
        self.targetClass = targetClass
        self.weight = weight
        self.caseID = caseID
    }
}
