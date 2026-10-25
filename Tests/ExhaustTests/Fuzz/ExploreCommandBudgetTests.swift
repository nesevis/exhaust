import Exhaust
import Testing

struct ExploreCommandBudgetTests {
    @Test func ordinaryRunsKeepTheirDeclaredBudget() {
        #expect(__ExhaustRuntime.exploreCommandBudget(declared: 123, environment: [:]) == 123)
        #expect(__ExhaustRuntime.exploreCommandBudget(declared: 0, environment: [:]) == 0)
    }

    @Test func commandBudgetOverridesThePropertyBudget() {
        #expect(__ExhaustRuntime.exploreCommandBudget(
            declared: 123,
            environment: ["EXHAUST_EXPLORE_TIME_NS": "60000000000"]
        ) == 60_000_000_000)
    }

    @Test(arguments: ["", "0", "-1", "1.5", "nan", "18446744073709551616"])
    func malformedOverridesAreRejected(value: String) {
        #expect(__ExhaustRuntime.exploreCommandBudget(
            declared: 123,
            environment: ["EXHAUST_EXPLORE_TIME_NS": value]
        ) == nil)
    }
}
