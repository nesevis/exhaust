//
//  ChoiceTree.swift
//  Exhaust
//
//  Created by Chris Kolbu on 16/7/2025.
//

enum ChoiceTree: Equatable {
    /// A primitive choice, typically a number or a high-level semantic label.
    case choice(ChoiceValue)
    
    /// A deterministic or constant value that can't be shrunk
    case just
    
    /// A node that represents the generation of a sequence. It explicitly
    /// captures the length and the choice trees for each of its elements.
    indirect case sequence(length: UInt64, elements: [ChoiceTree], validRange: ClosedRange<UInt64>)
    
    /// A node that represents a branching choice made via `pick`.
    indirect case branch(label: UInt64, children: [ChoiceTree])
    
    /// Represents a nested group of choices that don't have a specific semantic meaning.
    indirect case group([ChoiceTree])
}

extension ChoiceTree {
    var complexity: UInt64 {
        switch self {
        case let .choice(value):
            switch value {
            case let .character(char):
                return char.bitPattern64
            case let .uint(uint):
                return uint
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
