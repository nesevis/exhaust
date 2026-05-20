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

    @Test("NaN transitivity: if a < b and b < c, then a < c")
    func nanTransitivity() {
        let small = ChoiceValue(0.5.bitPattern64, tag: .double)
        let nan = ChoiceValue(Double.nan.bitPattern64, tag: .double)
        let large = ChoiceValue(1.0.bitPattern64, tag: .double)

        #expect(small < large)

        let nanEquivSmall = ((nan < small) == false) && ((small < nan) == false)
        let nanEquivLarge = ((nan < large) == false) && ((large < nan) == false)
        let smallEquivLarge = ((small < large) == false) && ((large < small) == false)

        if nanEquivSmall, nanEquivLarge {
            #expect(smallEquivLarge, "Transitivity of equivalence violated")
        }
    }
}
