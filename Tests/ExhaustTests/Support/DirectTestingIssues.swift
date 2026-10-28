import Testing

/// Absorbs the issues Exhaust's non-Apple reporting shim records directly with swift-testing.
///
/// On Apple platforms `withIssueReporters` redirects error reporting away from swift-testing, so the body runs bare. On non-Apple platforms the shim's direct `Issue.record` delivery cannot be redirected, so these helpers absorb those records as known issues.
enum DirectTestingIssues {
    /// Runs `body`, absorbing the issues Exhaust's non-Apple reporting shim records directly with swift-testing.
    static func absorbing<Value>(
        isIntermittent: Bool = false,
        _ body: () -> Value
    ) -> Value {
        #if canImport(ObjectiveC)
            return body()
        #else
            var captured: Value?
            withKnownIssue(isIntermittent: isIntermittent) {
                captured = body()
            }
            guard let captured else {
                fatalError("withKnownIssue did not run its body")
            }
            return captured
        #endif
    }

    /// Runs async `body`, absorbing the issues Exhaust's non-Apple reporting shim records directly with swift-testing.
    ///
    /// The direct record happens on a bridged thread where the swift-testing test association may not propagate, so async callers pass `isIntermittent: true`.
    static func absorbing<Value>(
        isIntermittent: Bool = false,
        _ body: () async -> Value
    ) async -> Value {
        #if canImport(ObjectiveC)
            return await body()
        #else
            var captured: Value?
            await withKnownIssue(isIntermittent: isIntermittent) {
                captured = await body()
            }
            guard let captured else {
                fatalError("withKnownIssue did not run its body")
            }
            return captured
        #endif
    }
}
