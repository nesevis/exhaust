////
////  ChoiceTree+Shortlex.swift
////  Exhaust
////
////  Created by Chris Kolbu on 29/7/2025.
////

extension ChoiceTree {
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
