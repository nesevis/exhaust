/// Runtime support for macro-expanded code. Not intended for direct use.
///
/// The `__` prefix follows Swift Testing's convention (`Testing.__check`, `Testing.__Expression`)
/// to signal that this is macro infrastructure, not public API.
@_spi(ExhaustInternal) import ExhaustCore
import IssueReporting

public enum __ExhaustRuntime { // swiftlint:disable:this type_name
    /// Runs a property test with the given generator, settings, and property.
    /// This is the runtime target of the `#exhaust` macro expansion.
    ///
    /// - Parameters:
    ///   - gen: The generator to produce test values from.
    ///   - settings: An array of `ExhaustSettings` controlling test behavior.
    ///   - sourceCode: A string representation of the property closure body, captured at compile time.
    ///     `nil` when a function reference is passed instead of a trailing closure.
    ///   - fileID: The file ID of the call site (injected by macro expansion).
    ///   - filePath: The file path of the call site (injected by macro expansion).
    ///   - line: The line number of the call site (injected by macro expansion).
    ///   - column: The column number of the call site (injected by macro expansion).
    ///   - property: The property to test — returns `true` for passing values.
    /// - Returns: The shrunk counterexample if the property failed, or `nil` if all iterations passed.
    @discardableResult
    public static func __exhaust<Output>(
        _ gen: ReflectiveGenerator<Output>,
        settings: [ExhaustSettings],
        sourceCode: String?,
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column,
        property: (Output) -> Bool,
    ) throws -> Output? {
        var maxIterations: UInt64 = 100
        var seed: UInt64?
        var shrinkConfig: ShrinkBudget = .fast
        var suppressIssueReporting = false

        for setting in settings {
            switch setting {
            case let .maxIterations(n):
                maxIterations = n
            case let .replay(s):
                seed = s
            case let .shrinkBudget(config):
                shrinkConfig = config
            case .suppressIssueReporting:
                suppressIssueReporting = true
            }
        }

        var iterations = 0
        var generator = ValueAndChoiceTreeInterpreter(
            gen,
            seed: seed,
            maxRuns: maxIterations,
        )
        let actualSeed = generator.baseSeed

        while let (next, tree) = generator.next() {
            iterations += 1
            let passed = property(next)
            if passed == false {
                if let (shrunkSequence, shrunkValue) = try Interpreters.reduce(
                    gen: gen,
                    tree: tree,
                    config: shrinkConfig,
                    property: property,
                ) {
                    let failure = PropertyTestFailure(
                        counterexample: shrunkValue,
                        original: next,
                        sourceCode: sourceCode,
                        seed: actualSeed,
                        iteration: iterations,
                        maxIterations: maxIterations,
                        blueprint: shrunkSequence.shortString,
                    )
                    let rendered = failure.render(format: ExhaustLog.configuration.format)
                    ExhaustLog.error(
                        category: .propertyTest,
                        event: "property_failed",
                        rendered,
                    )
                    ExhaustLog.debug(
                        category: .propertyTest,
                        event: "shrunk_blueprint",
                        "\(shrunkSequence.shortString)",
                    )
                    if !suppressIssueReporting {
                        reportIssue(
                            rendered,
                            fileID: fileID,
                            filePath: filePath,
                            line: line,
                            column: column,
                        )
                    }
                    return shrunkValue
                }

                // Shrinking failed — report the original counterexample
                let failure = PropertyTestFailure(
                    counterexample: next,
                    original: nil as Output?,
                    sourceCode: sourceCode,
                    seed: actualSeed,
                    iteration: iterations,
                    maxIterations: maxIterations,
                    blueprint: nil,
                )
                let rendered = failure.render(format: ExhaustLog.configuration.format)
                ExhaustLog.error(
                    category: .propertyTest,
                    event: "property_failed",
                    rendered,
                )
                reportIssue(
                    rendered,
                    fileID: fileID,
                    filePath: filePath,
                    line: line,
                    column: column,
                )
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
            metadata: passMetadata,
        )
        return nil
    }
}
