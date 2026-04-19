////
////  ChoiceTree+Shortlex.swift
////  Exhaust
////
////  Created by Chris Kolbu on 29/7/2025.
////

package extension ChoiceTree {
    var metadata: ChoiceMetadata {
        switch self {
        case let .choice(_, meta), let .sequence(_, _, meta):
            return meta
        case let .group(array, _):
            if let meta = array.first(where: { $0.metadata.validRange != nil })?.metadata {
                return meta
            }
            return ChoiceMetadata(validRange: nil)
        case let .bind(_, _, bound):
            return bound.metadata
        default:
            return ChoiceMetadata(validRange: nil)
        }
    }
}
