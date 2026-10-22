import Testing
@testable import ExhaustCore

@Suite("Sequence patch hashing and restoration")
struct SequencePatchTests {
    @Test("Empty, inline, and multiple edits match full hashing and restore every entry", arguments: [0, 1, 2, 4, 8])
    func hashAndRestore(editCount: Int) {
        let baseline = ChoiceSequence((0 ..< 16).map { value in
            ChoiceSequenceValue.value(.init(
                choice: ChoiceValue(UInt64(value), tag: .uint64),
                validRange: 0 ... 100,
                isRangeExplicit: true
            ))
        })
        var patch = SequencePatch()
        var expected = baseline
        for index in 0 ..< editCount {
            let position = index * 2
            let replacement: ChoiceSequenceValue = index.isMultiple(of: 2)
                ? .just
                : .value(.init(choice: ChoiceValue(UInt64(99), tag: .uint64), validRange: nil))
            let edit = SequencePatch.Edit(position: position, replacement: replacement)
            switch index {
                case 0:
                    patch = SequencePatch(edit)
                default:
                    patch.append(edit)
            }
            expected[position] = replacement
        }

        #expect(patch.count == editCount)
        #expect(Array(patch.reversed().map(\.position)) == (0 ..< editCount).reversed().map { $0 * 2 })
        #expect(
            patch.hash(baseHash: ZobristHash.hash(of: baseline), baseSequence: baseline)
                == ZobristHash.hash(of: expected)
        )
        var buffer = baseline
        for _ in 0 ..< 3 {
            patch.write(into: &buffer)
            #expect(buffer == expected)
            patch.restore(into: &buffer, baseSequence: baseline)
            #expect(buffer == baseline)
        }
    }
}
