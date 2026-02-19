//
//  UnlockProbeInput.swift
//  Exhaust
//
//  Created by Chris Kolbu on 20/2/2026.
//

struct UnlockProbeInput {
    let seqIdx: Int
    let choiceTag: TypeTag
    let currentEntry: ChoiceSequenceValue
    let currentBP: UInt64
    let targetBP: UInt64
    let semanticTargetBP: UInt64
    let validRanges: [ClosedRange<UInt64>]
}
