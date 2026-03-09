//
//  UnlockProbeInput.swift
//  Exhaust
//
//  Created by Chris Kolbu on 20/2/2026.
//

public struct UnlockProbeInput {
    public let seqIdx: Int
    public let choiceTag: TypeTag
    public let currentEntry: ChoiceSequenceValue
    public let currentBP: UInt64
    public let targetBP: UInt64
    public let semanticTargetBP: UInt64
    public let validRange: ClosedRange<UInt64>?
    public let isRangeExplicit: Bool

    public init(seqIdx: Int, choiceTag: TypeTag, currentEntry: ChoiceSequenceValue, currentBP: UInt64, targetBP: UInt64, semanticTargetBP: UInt64, validRange: ClosedRange<UInt64>?, isRangeExplicit: Bool) {
        self.seqIdx = seqIdx
        self.choiceTag = choiceTag
        self.currentEntry = currentEntry
        self.currentBP = currentBP
        self.targetBP = targetBP
        self.semanticTargetBP = semanticTargetBP
        self.validRange = validRange
        self.isRangeExplicit = isRangeExplicit
    }
}
