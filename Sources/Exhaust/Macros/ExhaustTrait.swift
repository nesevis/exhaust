#if canImport(Testing)
    import ExhaustCore
    @_weakLinked import Testing

    /// Carries configuration for the `.exhaust(...)` trait attached to a test function.
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
    /// ```swift
    /// @Test(.exhaust(.budget(.thorough)))
    /// func ageIsNonNegative() { ... }
    ///
    /// @Test(.exhaust(.budget(.thorough), .regressions("3RT5GH8KM2", "9WXY1CV7")))
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

    // MARK: - Trait Options

    /// A configuration option for the `.exhaust(...)` test trait.
    ///
    /// Pass one or more options to `.exhaust(...)` to configure property test behavior at the test or suite level:
    ///
    /// ```swift
    /// @Test(.exhaust(.budget(.thorough)))
    /// @Test(.exhaust(.budget(.thorough), .regressions("3RT5GH8KM2", "9WXY1CV7")))
    /// @Suite(.exhaust(.budget(.extensive)))
    /// ```
    public struct ExhaustTraitOption: Sendable {
        enum Kind: Sendable {
            case budget(ExhaustBudget)
            case regressions([String])
        }

        let kind: Kind

        /// Sets the iteration budget for coverage, sampling, and reduction.
        ///
        /// Applies to all `#exhaust` calls in the test (or suite) that do not specify an inline `.budget(...)` setting. Inline settings take precedence.
        public static func budget(_ budget: ExhaustBudget) -> ExhaustTraitOption {
            ExhaustTraitOption(kind: .budget(budget))
        }

        /// Registers Crockford Base32 encoded seeds to replay before the normal pipeline.
        ///
        /// Each seed is replayed in order. If a regression now passes, a warning is reported suggesting removal.
        public static func regressions(_ seeds: String...) -> ExhaustTraitOption {
            ExhaustTraitOption(kind: .regressions(seeds))
        }
    }

    // MARK: - Builder API

    public extension Trait where Self == ExhaustTrait {
        /// Configures `#exhaust` property tests with the given options.
        ///
        /// ```swift
        /// @Test(.exhaust(.budget(.thorough)))
        /// @Test(.exhaust(.budget(.thorough), .regressions("3RT5GH8KM2", "9WXY1CV7")))
        /// @Suite(.exhaust(.budget(.extensive)))
        /// ```
        ///
        /// - Parameter options: Configuration options for the property test.
        static func exhaust(_ options: ExhaustTraitOption...) -> ExhaustTrait {
            var budget: ExhaustBudget?
            var regressions: [String] = []
            for option in options {
                switch option.kind {
                case let .budget(value):
                    budget = value
                case let .regressions(seeds):
                    regressions.append(contentsOf: seeds)
                }
            }
            return ExhaustTrait(budget: budget, regressions: regressions)
        }
    }

    // MARK: - Tags

    public extension Tag {
        /// Identifies property-based tests driven by `#exhaust`.
        @Tag static var propertyTest: Self
    }
#endif
