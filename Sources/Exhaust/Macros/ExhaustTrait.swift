#if canImport(Testing)
    import ExhaustCore
    @_weakLinked import Testing

    /// Configuration carried by the `.exhaust(...)` trait, accessible to `#exhaust` at runtime via `@TaskLocal`.
    public struct ExhaustTraitConfiguration: Sendable {
        /// The iteration budget, or `nil` to use the inline setting or default.
        public var budget: ExhaustBudget?

        /// Regression seeds (Crockford Base32 encoded) to replay at the start of each run.
        public var regressions: [String]

        /// The active trait configuration for the current test, set by ``ExhaustTrait``'s `provideScope` method.
        @TaskLocal public static var current: ExhaustTraitConfiguration?
    }

    /// A Swift Testing trait that configures `#exhaust` property tests.
    ///
    /// Budget is a positional parameter (most commonly varied). Regressions are variadic:
    ///
    /// ```swift
    /// @Test(.exhaust(.expensive))
    /// func ageIsNonNegative() { ... }
    ///
    /// @Test(.exhaust(.expensive, regressions: "3RT5GH8KM2", "9WXY1CV7"))
    /// func ageIsNonNegative() { ... }
    /// ```
    ///
    /// The trait composes with other Swift Testing traits (`.timeLimit`, `.bug(...)`, `.tags(...)`)
    /// and automatically adds the `.propertyTest` tag.
    public struct ExhaustTrait: TestTrait, TestScoping {
        let budget: ExhaustBudget?
        let regressions: [String]

        public var comments: [Comment] {
            []
        }

        public func prepare(for _: Test) async throws {
            // No-op — configuration is applied via provideScope.
        }

        /// Sets the trait configuration as a task-local for the duration of the test body.
        ///
        /// The `testCase` parameter is intentionally ignored. Since `#exhaust` drives its own iteration internally rather than using `@Test(arguments:)`, the trait always hits the single-case path.
        public func provideScope(
            for _: Test,
            testCase _: Test.Case?,
            performing function: @Sendable () async throws -> Void
        ) async throws {
            let config = ExhaustTraitConfiguration(
                budget: budget,
                regressions: regressions
            )
            try await ExhaustTraitConfiguration.$current.withValue(config) {
                try await function()
            }
        }
    }

    // MARK: - Builder API

    public extension Trait where Self == ExhaustTrait {
        /// Configures an `#exhaust` property test with the given budget and regression seeds.
        ///
        /// ```swift
        /// @Test(.exhaust(.expensive))
        /// @Test(.exhaust(.expensive, regressions: "3RT5GH8KM2", "9WXY1CV7"))
        /// ```
        ///
        /// - Parameters:
        ///   - budget: The iteration budget for coverage, sampling, and reduction.
        ///   - regressions: Crockford Base32 encoded seeds to replay before the normal pipeline.
        static func exhaust(
            _ budget: ExhaustBudget,
            regressions: String...
        ) -> ExhaustTrait {
            ExhaustTrait(budget: budget, regressions: regressions)
        }

        /// Configures an `#exhaust` property test with default budget and regression seeds.
        ///
        /// ```swift
        /// @Test(.exhaust(regressions: "3RT5GH8KM2", "9WXY1CV7"))
        /// ```
        ///
        /// - Parameter regressions: Crockford Base32 encoded seeds to replay before the normal pipeline.
        static func exhaust(
            regressions: String...
        ) -> ExhaustTrait {
            ExhaustTrait(budget: nil, regressions: regressions)
        }
    }

    // MARK: - Tags

    public extension Tag {
        /// Tag for property-based tests driven by `#exhaust`.
        @Tag static var propertyTest: Self
    }
#endif
