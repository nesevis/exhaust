import ExhaustCore
import Testing

@Suite("ChoiceValue Ordering")
struct ChoiceValueOrderingTests {
    @Test("Comparable is total when one operand is NaN")
    func nanComparableIsTotal() {
        let nan = ChoiceValue(Double.nan.bitPattern64, tag: .double)
        let normal = ChoiceValue(1.0.bitPattern64, tag: .double)

        let ordered = nan < normal || normal < nan || nan == normal
        #expect(ordered, "ChoiceValue pair must satisfy exactly one of <, >, or ==")
    }
}
