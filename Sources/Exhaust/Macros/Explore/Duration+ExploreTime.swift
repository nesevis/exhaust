// Minute and hour factories for `#explore(time:)` budgets.

/// Factories for the wall-clock budgets `#explore(time:)` takes, at the granularities soak runs are written in.
@available(macOS 13.0, iOS 16.0, macCatalyst 16.0, tvOS 16.0, watchOS 9.0, *)
public extension Duration {
    /// Creates a duration from a whole number of minutes.
    ///
    /// The standard library stops at `.seconds(_:)`; this overload lets a soak budget read as `#explore(time: .minutes(15))` instead of `.seconds(900)`.
    static func minutes(_ minutes: Int) -> Duration {
        .seconds(minutes * 60)
    }

    /// Creates a duration from a whole number of hours.
    ///
    /// The standard library stops at `.seconds(_:)`; this overload lets a soak budget read as `#explore(time: .hours(1))` instead of `.seconds(3600)`.
    static func hours(_ hours: Int) -> Duration {
        .seconds(hours * 3600)
    }
}
