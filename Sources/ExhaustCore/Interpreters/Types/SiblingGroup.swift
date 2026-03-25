//
//  SiblingGroup.swift
//  Exhaust
//
//  Created by Chris Kolbu on 15/2/2026.
//

import Foundation

public struct SiblingGroup: Equatable {
    /// Each sibling's range in the sequence. Contiguous, non-overlapping, in order.
    public let ranges: [ClosedRange<Int>]
    public let depth: Int
    public let kind: SiblingChildKind

    public var valueRanges: [ClosedRange<Int>]? {
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

public enum SiblingChildKind: Equatable {
    case bareValue
    case sequence
    case group
}

public struct SiblingFrame {
    public var children: [(range: ClosedRange<Int>, kind: SiblingChildKind)] = []
    public let depth: Int
    public let startIndex: Int
    public let isSequence: Bool

    public init(
      children: [(range: ClosedRange<Int>, kind: SiblingChildKind)] = [],
      depth: Int,
      startIndex: Int,
      isSequence: Bool
    ) {
        self.children = children
        self.depth = depth
        self.startIndex = startIndex
        self.isSequence = isSequence
    }
}
