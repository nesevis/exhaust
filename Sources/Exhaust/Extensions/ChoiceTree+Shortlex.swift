//
//  ChoiceTree+Shortlex.swift
//  Exhaust
//
//  Created by Chris Kolbu on 29/7/2025.
//

extension ChoiceTree {
    var shortlexLength: UInt64 {
        switch self {
        case .choice:
            return 1
        case .sequence(let length, let elements, _):
            return length + elements.map(\.shortlexLength).reduce(0, +)
        case .branch(_, let children), .group(let children):
            return 1 + children.map(\.shortlexLength).reduce(0, +)
            // Cases with no intrinsic complexity
        case .getSize, .just:
            return 0
        case .important(let child):
            return child.shortlexLength - 1
        case .selected(let child):
            return child.shortlexLength
        case .resize(_, let choices):
            return choices.map(\.shortlexLength).reduce(0, +)
        }
    }
}

extension ChoiceTree {
    func shortlexPrecedes(_ other: ChoiceTree) -> Bool {
        // 1. SHORT: Compare by length (shorter is better)
        let lhsLength = self.shortlexLength
        let rhsLength = other.shortlexLength
        
        if lhsLength != rhsLength {
            return lhsLength < rhsLength
        }
        
        // 2. LEX: For equal lengths, compare lexicographically
        return self.lexicographicallyPrecedes(other)
    }
    
    private func lexicographicallyPrecedes(_ other: ChoiceTree) -> Bool {
        switch (self, other) {
        case let (.choice(lhsValue, _), .choice(rhsValue, _)):
            return lhsValue < rhsValue
            
        case let (.sequence(lhsLength, lhsElements, _), .sequence(rhsLength, rhsElements, _)):
            if lhsLength != rhsLength {
                return lhsLength < rhsLength
            }
            return lhsElements.lexicographicallyPrecedes(rhsElements) {
                $0.shortlexPrecedes($1)
            }
            
        case let (.branch(lhsLabel, lhsChildren), .branch(rhsLabel, rhsChildren)):
            if lhsLabel != rhsLabel {
                return lhsLabel < rhsLabel
            }
            return lhsChildren.lexicographicallyPrecedes(rhsChildren) {
                $0.shortlexPrecedes($1) }
            
        case let (.group(lhsChildren), .group(rhsChildren)):
            return lhsChildren.lexicographicallyPrecedes(rhsChildren) {
                $0.shortlexPrecedes($1) }
            
        case let (.resize(lhsSize, lhsChoices), .resize(rhsSize, rhsChoices)):
            if lhsSize != rhsSize {
                return lhsSize < rhsSize
            }
            return lhsChoices.lexicographicallyPrecedes(rhsChoices) {
                $0.shortlexPrecedes($1) }
            
        case let (.important(lhsChild), .important(rhsChild)),
            let (.selected(lhsChild), .selected(rhsChild)):
            return lhsChild.shortlexPrecedes(rhsChild)
            
        case let (.getSize(lhsSize), .getSize(rhsSize)):
            return lhsSize < rhsSize
            
        case (.just(let lhsType), .just(let rhsType)):
            return lhsType < rhsType
            
        // Different node types: establish canonical ordering
        default:
            return self.typeOrder < other.typeOrder
        }
    }
    
    var typeOrder: Int {
        switch self {
        case .important: return -2     // Highest priority - guides shrinking
        case .selected: return -1      // High priority - replay markers
        case .just: return 0           // Constants - no complexity
        case .getSize: return 0        // Size markers - no complexity
        case .resize: return 0         // Context modifiers
        case .choice: return 1         // Single shrinkable values
        case .group: return 3          // Simple containers
        case .branch: return 4         // Choice points with alternatives
        case .sequence: return 5       // Variable-length structures
        }
    }
}
