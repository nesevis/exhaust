import Testing
@testable import ExhaustCore

@Suite("Screening elided arms")
struct ScreeningElidedArmTests {
    @Test("A pick whose unselected arm binds is never an exhaustive candidate")
    func bindingArmPreventsExhaustiveCandidacy() throws {
        // Shaped like the recursive generators that first exposed this: a payload-free arm beside one whose
        // shape depends on a drawn value. Screening analysis records only the arm it selected, so when it
        // selects the payload-free one the template holds no evidence that the other arm exists.
        let binding = Gen.choose(in: UInt64(0) ... 3).wrapped(isReflective: true).bind { value in
            ReflectiveGenerator<UInt64>.just(value)
        }.gen
        let generator = Gen.pick(choices: [
            (weight: 1, generator: Gen.just(UInt64(0))),
            (weight: 7, generator: binding),
        ])
        let plan = try #require(ScreeningRunner.plan(generator, screeningBudget: 200))
        #expect(plan.isExhaustiveCandidate == false)
    }

    @Test("A pick whose arms are all bind-free remains an exhaustive candidate")
    func bindFreeArmsRemainExhaustive() throws {
        // The positive control: eliding these arms loses nothing, so the domain really is swept by its rows.
        let generator = Gen.pick(choices: [
            (weight: 1, generator: Gen.just(UInt64(0))),
            (weight: 1, generator: Gen.just(UInt64(1))),
        ])
        let plan = try #require(ScreeningRunner.plan(generator, screeningBudget: 200))
        #expect(plan.isExhaustiveCandidate)
    }

    @Test("Data dependence is read from the generator, not from a tree that records one path")
    func dataDependenceReadsTheGenerator() {
        #expect(Gen.just(UInt64(0)).hasDataDependentShape == false)
        #expect(Gen.choose(in: UInt64(0) ... 3).hasDataDependentShape == false)
        #expect(Gen.zip(Gen.just(UInt64(0)), Gen.just(UInt64(1))).hasDataDependentShape == false)

        let binding = Gen.choose(in: UInt64(0) ... 3).wrapped(isReflective: true)
            .bind { ReflectiveGenerator<UInt64>.just($0) }
            .gen
        #expect(binding.hasDataDependentShape)
        // Reached only through the unselected arm, which is the position that used to go unreported.
        let mixed = Gen.pick(choices: [
            (weight: 1, generator: Gen.just(UInt64(0))),
            (weight: 1, generator: binding),
        ])
        #expect(mixed.hasDataDependentShape)
        #expect(Gen.zip(Gen.just(UInt64(0)), binding).hasDataDependentShape)
    }

    @Test("Collection combinators that depend on a drawn collection reify that dependence")
    func collectionCombinatorsReifyTheirDependence() {
        let source = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 3), exactly: 4)
        #expect(source.hasDataDependentShape == false)
        // Both draw a value and then build a generator shaped by it, so neither may read as fixed.
        #expect(Gen.shuffled(source).hasDataDependentShape)
        #expect(Gen.slice(of: source).hasDataDependentShape)
    }
}
