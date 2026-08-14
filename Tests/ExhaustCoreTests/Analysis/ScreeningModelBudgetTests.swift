import Foundation
import Testing
@testable import ExhaustCore

@Suite("Screening model budget")
struct ScreeningModelBudgetTests {
    @Test("The model budget scales the row budget and saturates on overflow")
    func modelBudgetScalesAndSaturates() {
        #expect(ScreeningRunner.modelBudget(for: 200) == 200 * ScreeningRunner.modelOverprovisionFactor)
        #expect(ScreeningRunner.modelBudget(for: .max) == .max)
    }

    @Test("A solo string generator is screenable at standard budget")
    func soloStringScreensAtStandardBudget() {
        let result = ScreeningRunner.run(
            Gen.string(length: 0 ... 20).gen,
            screeningBudget: 200,
            coveringSeed: 0,
            property: { _ in true }
        )
        guard case let .partial(summary, _, _, parameters, _, _) = result else {
            Issue.record("Expected partial screening, got \(result)")
            return
        }
        #expect(parameters == 1)
        #expect(summary.propertyInvocations > 0)
    }

    @Test("String x int keeps the composite slot at standard budget")
    func stringByIntKeepsCompositeAtStandardBudget() {
        let generator = Gen.zip(Gen.string(length: 0 ... 20).gen, Gen.choose(in: 0 ... 1000))
        let result = ScreeningRunner.run(
            generator,
            screeningBudget: 200,
            coveringSeed: 0,
            property: { _ in true }
        )
        guard case let .partial(_, _, _, parameters, _, _) = result else {
            Issue.record("Expected partial screening, got \(result)")
            return
        }
        #expect(parameters == 2, "The composite slot must survive as a screening parameter alongside the int")
    }

    @Test("A date array degrades to the halved model instead of going opaque")
    func dateArrayScreensAtStandardBudget() {
        let lowerDate = Date(timeIntervalSinceReferenceDate: 0)
        let upperDate = lowerDate.addingTimeInterval(86400 * 365)
        let dateGen = Gen.date(between: lowerDate ... upperDate, interval: DateStride.hours(1)).gen
        let generator = Gen.zip(Gen.arrayOf(dateGen, within: 0 ... 5), Gen.choose(in: 0 ... 1000))
        let result = ScreeningRunner.run(
            generator,
            screeningBudget: 200,
            coveringSeed: 0,
            property: { _ in true }
        )
        guard case let .partial(_, _, _, parameters, _, _) = result else {
            Issue.record("Expected partial screening, got \(result)")
            return
        }
        #expect(parameters == 2, "The date composite must degrade to the halved model, not drop as opaque")
    }

    @Test("The single-parameter sweep rotates with the covering seed")
    func singleParameterSweepRotatesWithCoveringSeed() {
        /// Domain 256 against budget 100: without rotation every run tests the same 100 values and the tail is permanently untestable.
        func observedValues(coveringSeed: UInt64) -> Set<Int> {
            var values = Set<Int>()
            let result = ScreeningRunner.run(
                Gen.choose(in: 0 ... 255),
                screeningBudget: 100,
                coveringSeed: coveringSeed,
                property: { value in
                    values.insert(value)
                    return true
                }
            )
            guard case .partial = result else {
                Issue.record("Expected partial screening, got \(result)")
                return values
            }
            return values
        }

        let firstWindow = observedValues(coveringSeed: 0)
        let secondWindow = observedValues(coveringSeed: 7)
        #expect(firstWindow.count == 100)
        #expect(secondWindow.count == 100)
        #expect(firstWindow != secondWindow, "Different covering seeds must sweep different value windows")
    }
}
