//
//  SiblingGroup.swift
//  Exhaust
//
//  Created by Chris Kolbu on 15/2/2026.
//

import Foundation

@_spi(ExhaustInternal) public struct SiblingGroup: Equatable {
    /// Each sibling's range in the sequence. Contiguous, non-overlapping, in order.
    @_spi(ExhaustInternal) public let ranges: [ClosedRange<Int>]
    @_spi(ExhaustInternal) public let depth: Int
    @_spi(ExhaustInternal) public let kind: SiblingChildKind

    var valueRanges: [ClosedRange<Int>]? {
        switch kind {
        case .bareValue:
            ranges
        case .sequence:
            nil
        case .group:
            nil
        }
    }
}

@_spi(ExhaustInternal) public enum SiblingChildKind: Equatable {
    case bareValue
    case sequence
    case group
}

struct SiblingFrame {
    var children: [(range: ClosedRange<Int>, kind: SiblingChildKind)] = []
    let depth: Int
    let startIndex: Int
    let isSequence: Bool
}
