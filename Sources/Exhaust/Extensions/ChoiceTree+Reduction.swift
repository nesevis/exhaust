//
//  ChoiceTree+Reduction.swift
//  Exhaust
//
//  Created by Chris Kolbu on 10/2/2026.
//

extension ChoiceTree {
    func refineEntireRange(using other: ChoiceTree, direction: ShrinkingDirection, markChangesAsImportant: Bool) -> ChoiceTree {
        self.mapWhereDifferent(to: other) { failing, passing in
            switch (failing, passing) {
            case let (.choice(failingChoice, failingMeta), .choice(passingChoice, _)):
                guard let range = failingChoice.refineRange(against: passingChoice, direction: direction) else {
                    return failing
                }
                let meta = ChoiceMetadata(validRanges: [range], strategies: failingMeta.strategies)
                return markChangesAsImportant
                    ? .important(.choice(failingChoice, meta))
                    : .choice(failingChoice, meta)
            case let (.sequence(failingLength, failingElements, _), .sequence(passingLength, passingElements, passingMeta)):
                guard let newRange = ChoiceValue(failingLength, tag: .uint64).refineRange(against: .init(passingLength, tag: .uint64), direction: direction) else {
                    return failing
                }
                let meta = ChoiceMetadata(validRanges: [newRange], strategies: passingMeta.strategies)
                return markChangesAsImportant
                    ? .important(.sequence(length: failingLength, elements: failingElements, meta))
                    : .sequence(length: failingLength, elements: failingElements, meta)
            default:
                return nil
            }
        }
    }
    
    func refineEndOfRange(using other: ChoiceTree, direction: ShrinkingDirection) -> ChoiceTree {
        self.mapWhereDifferent(to: other) { new, old in
            switch (new, old) {
            case let (.choice(newChoice, newMeta), .choice(oldChoice, _)):
                guard let range = newChoice.refineOneEndOfRange(against: oldChoice, range: newMeta.validRanges[0]) else {
                    return new
                }
                let meta = ChoiceMetadata(validRanges: [range], strategies: newMeta.strategies)
                return .choice(newChoice, meta)
            case let (.sequence(newLength, newElements, newMeta), .sequence(oldLength, _, _)):
                guard let newRange = ChoiceValue(newLength, tag: .uint64).refineOneEndOfRange(against: .init(oldLength, tag: .uint64), range: newMeta.validRanges[0]) else {
                    return new
                }
                let meta = ChoiceMetadata(validRanges: [newRange], strategies: newMeta.strategies)
                return .sequence(length: newLength, elements: newElements, meta)
            default:
                return nil
            }
        }
    }
}
