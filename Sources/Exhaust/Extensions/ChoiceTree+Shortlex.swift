////
////  ChoiceTree+Shortlex.swift
////  Exhaust
////
////  Created by Chris Kolbu on 29/7/2025.
////

extension ChoiceTree {
    #warning("Deprecated — remove")
    var typeId: Int {
        switch self {
        case .important: return 0 // Highest priority - guides shrinking
        case .selected: return 1 // High priority - replay markers
        case .just: return 2 // Constants - no complexity
        case .getSize: return 3 // Size markers - no complexity
        case .resize: return 4 // Context modifiers
        case .choice: return 5 // Single shrinkable values
        case .group: return 6 // Simple containers
        case .branch: return 7 // Choice points with alternatives
        case .sequence: return 8 // Variable-length structures
        }
    }
    
    var metadata: ChoiceMetadata {
        switch self {
        case let .choice(_, meta), let .sequence(_, _, meta):
            return meta
        case let .group(array):
            if let meta = array.first(where: { $0.metadata.validRanges.isEmpty == false })?.metadata {
                return meta
            }
            fallthrough
        default:
            return ChoiceMetadata(validRanges: [])
        }
    }
}
