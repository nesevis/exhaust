//
//  ChoiceSequenceValue+BitPattern.swift
//  Exhaust
//

// MARK: - ChoiceSequence Value Helpers

extension ChoiceSequenceValue {
    /// Returns a copy of this entry with the value's bit pattern replaced, preserving range metadata and type tag.
    ///
    /// - Precondition: The entry must be a `.value` case. Calling on structural markers (`.group`, `.sequence`, `.bind`, `.branch`, `.just`) triggers a precondition failure.
    func withBitPattern(_ bitPattern: UInt64) -> ChoiceSequenceValue {
        switch self {
            case let .value(value):
                let newChoice = ChoiceValue(
                    bitPattern,
                    tag: value.choice.tag
                )
                return .value(.init(
                    choice: newChoice,
                    validRange: value.validRange,
                    isRangeExplicit: value.isRangeExplicit
                ))
            default:
                preconditionFailure("withBitPattern called on non-value entry: \(self)")
        }
    }
}
