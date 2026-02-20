//
//  SequenceSemanticStats.swift
//  Exhaust
//
//  Created by Chris Kolbu on 20/2/2026.
//

struct SequenceSemanticStats {
    private var nonSemanticFlags: [Bool]
    private(set) var nonSemanticCount: Int

    init(sequence: ChoiceSequence) {
        nonSemanticFlags = [Bool]()
        nonSemanticFlags.reserveCapacity(sequence.count)

        var count = 0
        for entry in sequence {
            let isNonSemantic = Self.isNonSemantic(entry)
            nonSemanticFlags.append(isNonSemantic)
            if isNonSemantic {
                count += 1
            }
        }
        nonSemanticCount = count
    }

    func nonSemanticCount(
        afterReplacing index: Int,
        with replacement: ChoiceSequenceValue,
    ) -> Int {
        nonSemanticCount + deltaForReplacement(at: index, with: replacement)
    }

    func nonSemanticCount(
        afterReplacing first: (index: Int, replacement: ChoiceSequenceValue),
        and second: (index: Int, replacement: ChoiceSequenceValue),
    ) -> Int {
        if first.index == second.index {
            return nonSemanticCount(afterReplacing: second.index, with: second.replacement)
        }
        return nonSemanticCount
            + deltaForReplacement(at: first.index, with: first.replacement)
            + deltaForReplacement(at: second.index, with: second.replacement)
    }

    mutating func applyReplacement(
        at index: Int,
        with replacement: ChoiceSequenceValue,
    ) {
        let before = nonSemanticFlags[index]
        let after = Self.isNonSemantic(replacement)
        guard before != after else { return }
        nonSemanticFlags[index] = after
        nonSemanticCount += after ? 1 : -1
    }

    mutating func applyReplacements(
        _ first: (index: Int, replacement: ChoiceSequenceValue),
        _ second: (index: Int, replacement: ChoiceSequenceValue),
    ) {
        if first.index == second.index {
            applyReplacement(at: second.index, with: second.replacement)
            return
        }
        applyReplacement(at: first.index, with: first.replacement)
        applyReplacement(at: second.index, with: second.replacement)
    }

    static func fullNonSemanticCount(in sequence: ChoiceSequence) -> Int {
        sequence.reduce(into: 0) { count, entry in
            if isNonSemantic(entry) {
                count += 1
            }
        }
    }

    private func deltaForReplacement(at index: Int, with replacement: ChoiceSequenceValue) -> Int {
        let before = nonSemanticFlags[index]
        let after = Self.isNonSemantic(replacement)
        if before == after {
            return 0
        }
        return after ? 1 : -1
    }

    private static func isNonSemantic(_ entry: ChoiceSequenceValue) -> Bool {
        guard let value = entry.value else { return false }
        return value.choice.shortlexKey != value.choice.semanticSimplest.shortlexKey
    }
}
