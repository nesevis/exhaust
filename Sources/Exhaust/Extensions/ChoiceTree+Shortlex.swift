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
        case .important: 0 // Highest priority - guides shrinking
        case .selected: 1 // High priority - replay markers
        case .just: 2 // Constants - no complexity
        case .getSize: 3 // Size markers - no complexity
        case .resize: 4 // Context modifiers
        case .choice: 5 // Single shrinkable values
        case .group: 6 // Simple containers
        case .branch: 7 // Choice points with alternatives
        case .sequence: 8 // Variable-length structures
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
