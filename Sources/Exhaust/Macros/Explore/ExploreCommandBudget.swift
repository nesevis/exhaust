// The command sets this only in the child test process. Both generator and spec runs
// pass through runExploreTimeCore, so one override covers every time-bounded entry point.

package extension __ExhaustRuntime {
    static func exploreCommandBudget(declared: UInt64, environment: [String: String]) -> UInt64? {
        guard let value = environment["EXHAUST_EXPLORE_TIME_NS"] else {
            return declared
        }
        guard let nanoseconds = UInt64(value), nanoseconds > 0 else {
            return nil
        }
        return nanoseconds
    }
}
