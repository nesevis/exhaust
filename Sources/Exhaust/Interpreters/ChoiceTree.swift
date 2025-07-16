//
//  ChoiceTree.swift
//  Exhaust
//
//  Created by Chris Kolbu on 16/7/2025.
//

enum ChoiceTree: Equatable {
    /// A primitive choice, typically a number or a high-level semantic label.
    case choice(String)
    
    /// A node that represents the generation of a sequence. It explicitly
    /// captures the length and the choice trees for each of its elements.
    indirect case sequence(length: Int, elements: [ChoiceTree])
    
    /// A node that represents a branching choice made via `pick`.
    indirect case branch(label: String, children: [ChoiceTree])
    
    /// Represents a nested group of choices that don't have a specific semantic meaning.
    indirect case group([ChoiceTree])
}
