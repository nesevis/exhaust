import Exhaust
import Testing

@Suite("optional factory")
struct OptionalFactoryTests {
    @Test("The static form infers under #gen")
    func staticFormInfersUnderGen() {
        let gen = #gen(.optional(.int(in: 0 ... 10)))
        #exhaust(gen, .replay(.numeric(1))) { value in
            value == nil || (0 ... 10).contains(value!)
        }
    }

    @Test("The static form honors custom weights")
    func staticFormHonorsWeights() {
        let gen = #gen(.optional(.int(in: 0 ... 10), someWeight: 1, noneWeight: 3))
        #exhaust(gen, .replay(.numeric(1))) { value in
            value == nil || (0 ... 10).contains(value!)
        }
    }

    @Test("The static and instance forms produce the same stream for a seed")
    func staticAndInstanceFormsAgree() throws {
        let staticValues = try #example(#gen(.optional(.int(in: 0 ... 10))), count: 20, seed: .numeric(7))
        let instanceValues = try #example(#gen(.int(in: 0 ... 10)).optional(), count: 20, seed: .numeric(7))
        #expect(staticValues == instanceValues)
    }
}
