// The command sets the override only in the child test process. Both generator and spec runs pass through runExploreTimeCore, so one resolution covers every time-bounded entry point.

package extension __ExhaustRuntime {
    /// Resolves the run's budget: the explore command's override when present, otherwise the declared budget. Either must be positive.
    static func resolvedExploreBudget(declared: TimeSpan, environment: [String: String]) throws(InvalidExploreBudget) -> UInt64 {
        guard let value = environment["EXHAUST_EXPLORE_TIME_NS"] else {
            guard declared.nanoseconds > 0 else {
                throw InvalidExploreBudget(message: "#explore(time:) requires a positive time budget; got \(declared.seconds)s.")
            }
            return declared.nanoseconds
        }
        guard let nanoseconds = UInt64(value), nanoseconds > 0 else {
            throw InvalidExploreBudget(message: "The explore command's --time budget is invalid; pass a positive whole number of seconds.")
        }
        return nanoseconds
    }
}

package struct InvalidExploreBudget: Error, Equatable {
    package let message: String
}
