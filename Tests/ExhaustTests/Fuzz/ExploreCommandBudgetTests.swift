import Exhaust
import Testing

struct ExploreCommandBudgetTests {
    @Test func ordinaryRunsKeepTheirDeclaredBudget() throws {
        #expect(try __ExhaustRuntime.resolvedExploreBudget(declared: .nanoseconds(123), environment: [:]) == 123)
    }

    @Test func ordinaryRunsRejectAZeroBudget() {
        let error = #expect(throws: InvalidExploreBudget.self) {
            try __ExhaustRuntime.resolvedExploreBudget(declared: .zero, environment: [:])
        }
        #expect(error?.message == "#explore(time:) requires a positive time budget; got 0.0s.")
    }

    @Test func commandBudgetOverridesThePropertyBudget() throws {
        #expect(try __ExhaustRuntime.resolvedExploreBudget(
            declared: .nanoseconds(123),
            environment: ["EXHAUST_EXPLORE_TIME_NS": "60000000000"]
        ) == 60_000_000_000)
    }

    @Test(arguments: ["", "0", "-1", "1.5", "nan", "18446744073709551616"])
    func malformedOverridesAreRejected(value: String) {
        let error = #expect(throws: InvalidExploreBudget.self) {
            try __ExhaustRuntime.resolvedExploreBudget(
                declared: .nanoseconds(123),
                environment: ["EXHAUST_EXPLORE_TIME_NS": value]
            )
        }
        #expect(error?.message == "The explore command's --time budget is invalid; pass a positive whole number of seconds.")
    }
}
