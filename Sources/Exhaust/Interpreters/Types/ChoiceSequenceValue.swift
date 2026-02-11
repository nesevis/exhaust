//
//  ChoiceSequenceValue.swift
//  Exhaust
//
//  Created by Chris Kolbu on 11/2/2026.
//

public enum ChoiceSequenceValue: Hashable, Equatable {
    /// The elements within the `true`---`false` range are logically grouped
    case group(Bool)
    /// Values that repeat within a sequence
    /// The elements within the `true`---`false` range are elements of the sequence
    case sequence(Bool)
    /// A marker for a branching choice.
    /// The `Value` contains the chosen index in the array
    /// This marker has no explicit closing marker
    case branch(Value)
    /// Individual values
    case value(Value)
    
    public var isValue: Bool {
        switch self {
        case .value: return true
        case .group: return false
        case .sequence: return false
        case .branch: return false
        }
    }
    
    public struct Value: Hashable, Equatable {
        let choice: ChoiceValue
        let validRanges: [ClosedRange<UInt64>]
    }
}
