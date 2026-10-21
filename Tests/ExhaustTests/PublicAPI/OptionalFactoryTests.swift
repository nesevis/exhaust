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

    @Test("Optional weights select both arms at the requested proportions", arguments: [(1, 3), (3, 1)])
    func staticFormHonorsWeights(someWeight: Int, noneWeight: Int) throws {
        let values = try #example(
            #gen(.optional(.int(in: 0 ... 10), someWeight: someWeight, noneWeight: noneWeight)),
            count: 1000, seed: .numeric(1)
        )
        #expect(values.count == 1000)
        let someCount = values.compactMap { $0 }.count
        let expected = 1000 * someWeight / (someWeight + noneWeight)
        #expect(abs(someCount - expected) < 100)
    }

    @Test("The static and instance forms produce the same stream for a seed")
    func staticAndInstanceFormsAgree() throws {
        let staticValues = try #example(#gen(.optional(.int(in: 0 ... 10))), count: 20, seed: .numeric(7))
        let instanceValues = try #example(#gen(.int(in: 0 ... 10)).optional(), count: 20, seed: .numeric(7))
        #expect(staticValues == instanceValues)
    }
}
