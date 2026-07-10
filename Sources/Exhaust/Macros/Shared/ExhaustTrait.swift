#if canImport(Testing)
    import ExhaustCore
    #if canImport(ObjectiveC)
        @_weakLinked import Testing
    #else
        import Testing // swiftlint:disable:this duplicate_imports
    #endif

    /// Carries configuration for the `.exhaust(...)` trait attached to a test function.
    public struct ExhaustTraitConfiguration: Sendable {
        /// The iteration budget, or `nil` to use the inline setting or default.
        public var budget: ExhaustBudget?

        /// Regression seeds (Crockford Base32 encoded) to replay at the start of each run.
        public var regressions: [String]

        /// The active trait configuration for the current test, set by ``ExhaustTrait``'s `provideScope` method.
        @TaskLocal public static var current: ExhaustTraitConfiguration?
    }

    /// A Swift Testing trait that configures `#exhaust` property tests and `#execute` spec tests.
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
        /// The `testCase` parameter is intentionally ignored. Since `#exhaust` and `#execute` drive their own iteration internally rather than using `@Test(arguments:)`, the trait always hits the single-case path.
        public func provideScope(
            for _: Test,
            testCase _: Test.Case?,
            performing function: @concurrent @Sendable () async throws -> Void
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

    /// A configuration option for the `.exhaust(...)` trait on a `@Test`.
    ///
    /// Pass one or more options to configure property test behavior:
    ///
    /// ```swift
    /// @Test(.exhaust(.budget(.thorough)))
    /// @Test(.exhaust(.budget(.thorough), .regressions("3RT5GH8KM2", "9WXY1CV7")))
    /// ```
    ///
    /// Regression seeds are a per-test concern, so they live here rather than on the suite option type. A `@Suite` takes ``ExhaustSuiteTraitOption``, which offers only `.budget(...)`, so `@Suite(.exhaust(.regressions(...)))` does not compile.
    public struct ExhaustTraitOption: Sendable {
        enum Kind: Sendable {
            case budget(ExhaustBudget)
            case regressions([String])
        }

        let kind: Kind

        /// Sets the iteration budget for screening, sampling, and reduction.
        ///
        /// Applies to all `#exhaust` and `#execute` calls in the test that do not specify an inline `.budget(...)` setting. Inline settings take precedence.
        public static func budget(_ budget: ExhaustBudget) -> ExhaustTraitOption {
            ExhaustTraitOption(kind: .budget(budget))
        }

        /// Registers Crockford Base32 encoded seeds to replay before the normal pipeline.
        ///
        /// Each seed is replayed in order. Seeds that now pass sit inert as silent regression guards — the test stays green until the property fails on that seed again.
        public static func regressions(_ seeds: String...) -> ExhaustTraitOption {
            ExhaustTraitOption(kind: .regressions(seeds))
        }
    }

    /// A configuration option for the `.exhaust(...)` trait on a `@Suite`.
    ///
    /// A suite supports only `.budget(...)`. Regression seeds are a per-test concern and are deliberately absent here, so `@Suite(.exhaust(.regressions(...)))` does not compile.
    ///
    /// ```swift
    /// @Suite(.exhaust(.budget(.extensive)))
    /// ```
    public struct ExhaustSuiteTraitOption: Sendable {
        enum Kind: Sendable {
            case budget(ExhaustBudget)
        }

        let kind: Kind

        /// Sets the default iteration budget for every `#exhaust` and `#execute` call in the suite.
        ///
        /// Applies to all `#exhaust` and `#execute` calls in the suite that do not specify an inline `.budget(...)` setting or a test-level `.exhaust(.budget(...))` trait. Those take precedence.
        public static func budget(_ budget: ExhaustBudget) -> ExhaustSuiteTraitOption {
            ExhaustSuiteTraitOption(kind: .budget(budget))
        }
    }

    // MARK: - Builder API

    /// Declared on TestTrait (not Trait) so it is invisible to implicit member lookup in a @Suite
    /// (any SuiteTrait) context. Paired with the suite builder being on SuiteTrait, each context sees
    /// exactly one `exhaust` overload, so neither `.exhaust(...)` call is ever ambiguous.
    public extension TestTrait where Self == ExhaustTrait {
        /// Configures `#exhaust` property tests and `#execute` spec tests with the given options.
        ///
        /// ```swift
        /// @Test(.exhaust(.budget(.thorough)))
        /// @Test(.exhaust(.budget(.thorough), .regressions("3RT5GH8KM2", "9WXY1CV7")))
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

    // MARK: - Suite Trait

    // TestTrait conformance is required, not optional.
    // Because isRecursive is true, Swift Testing propagates this trait down to every child @Test function and inserts it into that test's trait list.
    // The Test.traits setter asserts that traits on a test function are TestTraits, so a SuiteTrait that is not also a TestTrait traps the runner during plan construction (a brk trap inside Runner.Plan._recursivelyApplyTraits) before any test runs.
    // This also matches the intended semantics below: the scope fires once per test function, which is only valid for a trait that test functions accept.
    // See swiftlang/swift-testing#1048.

    /// A Swift Testing trait that sets a default iteration budget for all `#exhaust` and `#execute` tests in a suite.
    ///
    /// Apply to a `@Suite` to set a budget that propagates to every test in the suite. Individual tests can override with an inline `.budget(...)` setting or a test-level `.exhaust(...)` trait.
    ///
    /// ```swift
    /// @Suite(.exhaust(.budget(.thorough)))
    /// struct MyPropertyTests {
    ///     @Test func sortedArrays() {
    ///         #exhaust(gen) { ... }  // inherits .thorough
    ///     }
    ///
    ///     @Test(.exhaust(.budget(.quick)))
    ///     func cheapCheck() {
    ///         #exhaust(gen) { ... }  // overrides to .quick
    ///     }
    /// }
    /// ```
    ///
    /// Regression seeds are per-test concerns and belong on `@Test(.exhaust(.regressions(...)))`.
    public struct ExhaustSuiteTrait: TestTrait, SuiteTrait, TestScoping {
        let budget: ExhaustBudget

        public var isRecursive: Bool {
            true
        }

        public var comments: [Comment] {
            []
        }

        /// Sets the suite budget as a task-local for the duration of each test body.
        ///
        /// The default `scopeProvider` for recursive ``SuiteTrait`` returns `nil` at the suite level and `self` at the test level, so this fires once per test function.
        public func provideScope(
            for _: Test,
            testCase _: Test.Case?,
            performing function: @concurrent @Sendable () async throws -> Void
        ) async throws {
            let config = ExhaustTraitConfiguration(
                budget: budget,
                regressions: []
            )
            try await ExhaustTraitConfiguration.$current.withValue(config) {
                try await function()
            }
        }
    }

    /// Declared on SuiteTrait, not Trait: a static member of SuiteTrait is invisible to implicit member
    /// lookup in a @Test (any TestTrait) context, so this overload never competes with the @Test builder.
    /// Without that, because ExhaustSuiteTrait is also a TestTrait, @Test(.exhaust(.budget(...))) would be
    /// ambiguous between ExhaustTrait and ExhaustSuiteTrait (both expose a .budget option).
    public extension SuiteTrait where Self == ExhaustSuiteTrait {
        /// Sets a default iteration budget for all `#exhaust` and `#execute` tests in a suite.
        ///
        /// ```swift
        /// @Suite(.exhaust(.budget(.thorough)))
        /// struct MyPropertyTests { ... }
        /// ```
        ///
        /// - Parameter options: Suite configuration. Only `.budget(...)` is available; regression seeds belong on `@Test`.
        static func exhaust(_ options: ExhaustSuiteTraitOption...) -> ExhaustSuiteTrait {
            var budget: ExhaustBudget = .standard
            for option in options {
                switch option.kind {
                    case let .budget(value):
                        budget = value
                }
            }
            return ExhaustSuiteTrait(budget: budget)
        }
    }

    // MARK: - Tags

    public extension Tag {
        /// Identifies property-based tests driven by `#exhaust`.
        @Tag static var propertyTest: Self
    }
#endif
