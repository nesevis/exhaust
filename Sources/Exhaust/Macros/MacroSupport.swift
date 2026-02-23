/// Runtime support for macro-expanded code. Not intended for direct use.
///
/// The `__` prefix follows Swift Testing's convention (`Testing.__check`, `Testing.__Expression`)
/// to signal that this is macro infrastructure, not public API.
// swiftlint:disable:next type_name
public enum __ExhaustRuntime {
    /// Runs a property test with the given generator, settings, and property.
    /// This is the runtime target of the `#exhaust` macro expansion.
    ///
    /// - Parameters:
    ///   - gen: The generator to produce test values from.
    ///   - settings: An array of `ExhaustSettings` controlling test behavior.
    ///   - sourceCode: A string representation of the property closure body, captured at compile time.
    ///     `nil` when a function reference is passed instead of a trailing closure.
    ///   - property: The property to test — returns `true` for passing values.
    /// - Returns: The shrunk counterexample if the property failed, or `nil` if all iterations passed.
    @discardableResult
    public static func __exhaust<Output>(
        _ gen: ReflectiveGenerator<Output>,
        settings: [ExhaustSettings],
        sourceCode: String?,
        property: (Output) -> Bool
    ) throws -> Output? {
        var maxIterations: UInt64 = 100
        var seed: UInt64?
        var shrinkConfig: Interpreters.ShrinkConfiguration = .fast

        for setting in settings {
            switch setting {
            case let .iterations(n):
                maxIterations = n
            case let .seed(s):
                seed = s
            case let .shrinkBudget(config):
                shrinkConfig = config
            }
        }

        var iterations = 0
        var generator = ValueAndChoiceTreeInterpreter(gen, seed: seed, maxRuns: maxIterations)

        while let (next, tree) = generator.next() {
            iterations += 1
            let passed = property(next)
            if passed == false {
                var failMetadata = [
                    "iteration": "\(iterations)",
                    "max_iterations": "\(maxIterations)",
                ]
                if let sourceCode {
                    failMetadata["source"] = sourceCode
                }
                ExhaustLog.error(
                    category: .propertyTest,
                    event: "property_failed",
                    metadata: failMetadata
                )
                ExhaustLog.notice(
                    category: .propertyTest,
                    event: "counterexample",
                    "\(next)"
                )

                if let (shrunkSequence, shrunkValue) = try Interpreters.reduce(
                    gen: gen,
                    tree: tree,
                    config: shrinkConfig,
                    property: property
                ) {
                    ExhaustLog.notice(
                        category: .propertyTest,
                        event: "shrunk_counterexample",
                        "\(shrunkValue)"
                    )
                    ExhaustLog.notice(
                        category: .propertyTest,
                        event: "counterexample_diff",
                        CounterexampleDiff.format(original: next, shrunk: shrunkValue)
                    )
                    ExhaustLog.notice(
                        category: .propertyTest,
                        event: "shrunk_blueprint",
                        "\(shrunkSequence.shortString)"
                    )
                    return shrunkValue
                }
                return nil
            }
        }

        var passMetadata = ["iterations": "\(maxIterations)"]
        if let sourceCode {
            passMetadata["source"] = sourceCode
        }
        ExhaustLog.notice(
            category: .propertyTest,
            event: "property_passed",
            metadata: passMetadata
        )
        return nil
    }
}
