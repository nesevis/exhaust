//
//  ChoiceTree.swift
//  Exhaust
//
//  Created by Chris Kolbu on 16/7/2025.
//

enum ChoiceTree: Equatable {
    /// A primitive choice, typically a number or a high-level semantic label.
    case choice(ChoiceValue, ChoiceMetadata)
    
    /// A deterministic or constant value that can't be shrunk
    /// This is encoded into the generator, and doesn't need to be part of the ``ChoiceTree``
    case just
    
    /// A node that represents the generation of a sequence. It explicitly
    /// captures the length and the choice trees for each of its elements.
    indirect case sequence(length: UInt64, elements: [ChoiceTree], ChoiceMetadata)
    
    /// A node that represents a branching choice made via `pick`.
    indirect case branch(label: UInt64, children: [ChoiceTree])
    
    /// Represents a nested group of choices that don't have a specific semantic meaning.
    indirect case group([ChoiceTree])
}

extension ChoiceTree {
    var complexity: UInt64 {
        switch self {
        case let .choice(value, metadata):
            switch value {
            case let .character(char):
                return char.bitPattern64
            case let .uint(uint):
                return metadata.semanticComplexity(for: uint)
            }
        case .just:
            return 0
        case .sequence(_, var elements, _), .branch(_, var elements), .group(var elements):
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
        }
    }
}

extension ChoiceTree: CustomDebugStringConvertible {
    var debugDescription: String {
        treeDescription(prefix: "", isLast: true)
    }
    
    private func treeDescription(prefix: String, isLast: Bool) -> String {
        let connector = isLast ? "└── " : "├── "
        let childPrefix = prefix + (isLast ? "    " : "│   ")
        
        switch self {
        case let .choice(value, _):
            switch value {
            case let .character(char):
                return prefix + connector + "choice(char: '\(char)')"
            case let .uint(uint):
                return prefix + connector + "choice(uint: \(uint))"
            }
            
        case .just:
            return prefix + connector + "just"
            
        case let .sequence(length, elements, _):
            var result = prefix + connector + "sequence(length: \(length))"
            for (index, element) in elements.enumerated() {
                let isLastElement = index == elements.count - 1
                result += "\n" + element.treeDescription(prefix: childPrefix, isLast: isLastElement)
            }
            return result
            
        case let .branch(label, children):
            var result = prefix + connector + "branch(label: \(label))"
            for (index, child) in children.enumerated() {
                let isLastChild = index == children.count - 1
                result += "\n" + child.treeDescription(prefix: childPrefix, isLast: isLastChild)
            }
            return result
            
        case let .group(children):
            var result = prefix + connector + "group"
            for (index, child) in children.enumerated() {
                let isLastChild = index == children.count - 1
                result += "\n" + child.treeDescription(prefix: childPrefix, isLast: isLastChild)
            }
            return result
        }
    }
}
