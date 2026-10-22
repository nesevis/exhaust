import Testing
@testable import ExhaustCore

@Suite("Edited choice sequences")
struct EditedChoiceSequenceTests {
    @Test("Value reads preserve markers and reject out-of-bounds indices", arguments: [false, true])
    func valueReads(hasReplacement: Bool) {
        let originalValue = ChoiceSequenceValue.Value(choice: ChoiceValue(UInt64(3), tag: .uint64), validRange: 0 ... 10)
        let replacement = ChoiceSequenceValueReplacement(
            index: 1,
            value: .init(choice: ChoiceValue(UInt64(7), tag: .uint8), validRange: 0 ... 20)
        )
        let base: ChoiceSequence = [.sequence(true), .value(originalValue), .sequence(false)]
        let sequence = hasReplacement ? EditedChoiceSequence(base, replacement: replacement) : EditedChoiceSequence(base)
        let expectedValue = hasReplacement ? replacement.value : originalValue
        #expect(sequence.count == base.count)
        #expect(sequence.base == base)
        #expect(sequence.value(at: 1) == expectedValue)
        for index in [Int.min, -1, 0, 2, 3, Int.max] {
            #expect(sequence.value(at: index) == nil)
        }
        #expect(sequence.materialized() == [.sequence(true), .value(expectedValue), .sequence(false)])
        var materialized = sequence.materialized()
        materialized.removeAll()
        #expect(sequence.value(at: 1) == expectedValue)
        #expect(base[1].value == originalValue)
        #expect(EditedChoiceSequence([]).value(at: 0) == nil)
    }

    @Test("Exact contexts hash and replay the edited prefix", arguments: [false, true], [nil, UInt64(1337)])
    func exactContext(materializePicks: Bool, precomputedSeed: UInt64?) {
        let base: ChoiceSequence = [.value(.init(choice: ChoiceValue(UInt64(3), tag: .uint64), validRange: 0 ... 10))]
        let replacement = ChoiceSequenceValueReplacement(index: 0, value: .init(choice: ChoiceValue(UInt64(7), tag: .uint64), validRange: 0 ... 10))
        let sequence = EditedChoiceSequence(base, replacement: replacement)
        var context = Materializer.Context(prefix: sequence, mode: .exact, materializePicks: materializePicks, precomputedSeed: precomputedSeed)
        let expectedSeed = precomputedSeed ?? (materializePicks ? ZobristHash.hash(of: sequence.materialized()) : 0)
        var expected = Xoshiro256(seed: expectedSeed)
        #expect(context.prng.next() == expected.next())
        #expect(context.cursor.tryConsumeValue() == replacement.value)
    }
}
