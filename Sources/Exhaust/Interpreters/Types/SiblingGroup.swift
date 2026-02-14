//
//  SiblingGroup.swift
//  Exhaust
//
//  Created by Chris Kolbu on 15/2/2026.
//

import Foundation

struct SiblingGroup {
    /// Each sibling's range in the sequence. Contiguous, non-overlapping, in order.
    let ranges: [ClosedRange<Int>]
    let depth: Int
}

enum SiblingChildKind: Equatable {
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
