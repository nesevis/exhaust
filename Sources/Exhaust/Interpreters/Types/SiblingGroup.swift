//
//  SiblingGroup.swift
//  Exhaust
//
//  Created by Chris Kolbu on 15/2/2026.
//

import Foundation

struct SiblingGroup: Equatable {
    /// Each sibling's range in the sequence. Contiguous, non-overlapping, in order.
    let ranges: [ClosedRange<Int>]
    let depth: Int
    let kind: SiblingChildKind
    
    var valueRanges: [ClosedRange<Int>]? {
        switch kind {
        case .bareValue:
            return ranges
        case .sequence:
            return nil
        case .group:
            return nil
            guard ranges.allSatisfy({ $0.count == 3 }) else {
                fatalError("Too hard basket?")
            }
            return ranges.map { ($0.lowerBound + 1)...($0.upperBound - 1) }
        }
    }
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
