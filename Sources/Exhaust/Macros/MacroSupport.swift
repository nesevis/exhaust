// Runtime support for macro-expanded code. Not intended for direct use.
//
// The `__` prefix follows Swift Testing's convention (`Testing.__check`, `Testing.__Expression`)
// to signal that this is macro infrastructure, not public API.
import ExhaustCore
import IssueReporting

public enum __ExhaustRuntime { // swiftlint:disable:this type_name
    /// Runs a property test with the given generator, settings, and property.
    /// This is the runtime target of the `#exhaust` macro expansion.
    ///
    /// - Parameters:
    ///   - gen: The generator to produce test values from.
    ///   - settings: An array of `ExhaustSettings` controlling test behavior.
    ///   - sourceCode: A string representation of the property closure body, captured at compile time. `nil` when a function reference is passed instead of a trailing closure.
    ///   - fileID: The file ID of the call site (injected by macro expansion).
    ///   - filePath: The file path of the call site (injected by macro expansion).
    ///   - line: The line number of the call site (injected by macro expansion).
    ///   - column: The column number of the call site (injected by macro expansion).
    ///   - property: The property to test — returns `true` for passing values.
    /// - Returns: The shrunk counterexample if the property failed, or `nil` if all iterations passed.
    @discardableResult
    public static func __exhaust<Output>(
        _ gen: ReflectiveGenerator<Output>,
        settings: [ExhaustSettings<Output>],
        sourceCode: String?,
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column,
        property: @Sendable (Output) -> Bool,
    ) -> Output? {
        var samplingBudget: UInt64 = 100
        var coverageBudget: UInt64 = 2000
        var seed: UInt64?
        var reductionConfig: TCRBudget = .fast
        var suppressIssueReporting = false
        var reflectingValue: Output?
        var useRandomOnly = false
        var useKleisliReducer = false

        for setting in settings {
            switch setting {
            case let .samplingBudget(n):
                samplingBudget = n
            case let .coverageBudget(n):
                coverageBudget = n
            case let .replay(s):
                seed = s
            case let .reductionBudget(config):
                reductionConfig = config
            case .suppressIssueReporting:
                suppressIssueReporting = true
            case let .reflecting(value):
                reflectingValue = value
            case .randomOnly:
                useRandomOnly = true
            case .useKleisliReducer:
                useKleisliReducer = true
            }
        }

        if let reflectingValue {
            do {
                return try __reduceReflected(
                    gen,
                    value: reflectingValue,
                    reductionConfig: reductionConfig,
                    useKleisliReducer: useKleisliReducer,
                    suppressIssueReporting: suppressIssueReporting,
                    sourceCode: sourceCode,
                    fileID: fileID,
                    filePath: filePath,
                    line: line,
                    column: column,
                    property: property,
                )
            } catch {
                reportIssue(
                    "\(error)",
                    fileID: fileID,
                    filePath: filePath,
                    line: line,
                    column: column,
                )
                return reflectingValue
            }
        }

        // --- Structured coverage phase ---
        var coverageIterations = 0
        if !useRandomOnly, seed == nil {
            let coverageResult = CoverageRunner.run(gen, coverageBudget: coverageBudget, property: property)
            switch coverageResult {
            case let .failure(value, tree, iteration):
                // Reflect to get a structurally correct tree with materialized picks,
                // since coverage-built trees lack unselected branches needed by reducer strategies.
                let shrinkTree = (try? Interpreters.reflect(gen, with: value)) ?? tree
                var propertyInvocationCount = 0
                let countingProperty: (Output) -> Bool = { value in
                    propertyInvocationCount += 1
                    return property(value)
                }
                do {
                    if let (shrunkSequence, shrunkValue) = try Interpreters.dispatchReduce(
                        gen: gen,
                        tree: shrinkTree,
                        config: reductionConfig,
                        useKleisli: useKleisliReducer,
                        property: countingProperty,
                    ) {
                        var failure = PropertyTestFailure(
                            counterexample: shrunkValue,
                            original: value,
                            sourceCode: sourceCode,
                            seed: nil,
                            iteration: iteration,
                            samplingBudget: samplingBudget,
                            blueprint: shrunkSequence.shortString,
                            propertyInvocations: propertyInvocationCount,
                        )
                        failure.replayHint = "No replay seed — found via systematic combinatorial coverage."
                        let rendered = failure.render(format: ExhaustLog.configuration.format)
                        ExhaustLog.error(
                            category: .propertyTest,
                            event: "property_failed",
                            rendered,
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
                } catch {
                    reportIssue(
                        "\(error)",
                        fileID: fileID,
                        filePath: filePath,
                        line: line,
                        column: column,
                    )
                    return value
                }

                // Reduction failed — report original
                var failure = PropertyTestFailure(
                    counterexample: value,
                    original: nil as Output?,
                    sourceCode: sourceCode,
                    seed: nil,
                    iteration: iteration,
                    samplingBudget: samplingBudget,
                    blueprint: nil,
                    propertyInvocations: propertyInvocationCount,
                )
                failure.replayHint = "No replay seed — found via systematic combinatorial coverage."
                let rendered = failure.render(format: ExhaustLog.configuration.format)
                ExhaustLog.error(
                    category: .propertyTest,
                    event: "property_failed",
                    rendered,
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
                return nil

            case let .exhaustive(iterations):
                ExhaustLog.notice(
                    category: .propertyTest,
                    event: "tway_coverage",
                    metadata: [
                        "exhaustive": "true",
                        "iterations": "\(iterations)",
                    ],
                )
                var passMetadata = [
                    "iterations": "\(iterations)",
                    "property_invocations": "\(iterations)",
                ]
                if let sourceCode {
                    passMetadata["source"] = sourceCode
                }
                ExhaustLog.notice(
                    category: .propertyTest,
                    event: "property_passed",
                    metadata: passMetadata,
                )
                return nil

            case let .partial(iterations, strength, rows, parameters, totalSpace, kind):
                coverageIterations = iterations
                ExhaustLog.notice(
                    category: .propertyTest,
                    event: "tway_coverage",
                    metadata: [
                        "strength": "\(strength)",
                        "covering_rows": "\(rows)",
                        "iterations": "\(iterations)",
                        "total_space": "\(totalSpace)",
                        "parameters": "\(parameters)",
                        "exhaustive": "false",
                        "kind": kind == .boundaryValue ? "boundary" : "finite",
                    ],
                )

            case .notApplicable:
                break
            }
        }
        // --- Random sampling phase (full maxIterations budget) ---

        var iterations = 0
        var generator = ValueAndChoiceTreeInterpreter(
            gen,
            materializePicks: true,
            seed: seed,
            maxRuns: samplingBudget,
        )
        let actualSeed = generator.baseSeed

        do { while let (next, tree) = try generator.next() {
            iterations += 1
            let passed = property(next)
            if passed == false {
                var propertyInvocationCount = 0
                let countingProperty: (Output) -> Bool = { value in
                    propertyInvocationCount += 1
                    return property(value)
                }
                do {
                    if let (shrunkSequence, shrunkValue) = try Interpreters.dispatchReduce(
                        gen: gen,
                        tree: tree,
                        config: reductionConfig,
                        useKleisli: useKleisliReducer,
                        property: countingProperty,
                    ) {
                        let failure = PropertyTestFailure(
                            counterexample: shrunkValue,
                            original: next,
                            sourceCode: sourceCode,
                            seed: actualSeed,
                            iteration: iterations,
                            samplingBudget: samplingBudget,
                            blueprint: shrunkSequence.shortString,
                            propertyInvocations: propertyInvocationCount,
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
                } catch {
                    reportIssue(
                        "\(error)",
                        fileID: fileID,
                        filePath: filePath,
                        line: line,
                        column: column,
                    )
                    return next
                }

                // Reduction failed — report the original counterexample
                let failure = PropertyTestFailure(
                    counterexample: next,
                    original: nil as Output?,
                    sourceCode: sourceCode,
                    seed: actualSeed,
                    iteration: iterations,
                    samplingBudget: samplingBudget,
                    blueprint: nil,
                    propertyInvocations: propertyInvocationCount,
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
        } catch {
            reportIssue(
                "\(error)",
                fileID: fileID,
                filePath: filePath,
                line: line,
                column: column,
            )
            return nil
        }

        let totalPropertyCalls = coverageIterations + iterations
        var passMetadata = [
            "iterations": "\(samplingBudget)",
            "property_invocations": "\(totalPropertyCalls)",
        ]
        if coverageIterations > 0 {
            passMetadata["coverage_invocations"] = "\(coverageIterations)"
            passMetadata["random_invocations"] = "\(iterations)"
        }
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

    // MARK: - Explore

    /// Runs a feedback-guided property test with hill-climbing mutation.
    /// This is the runtime target of the `#explore` macro expansion.
    @discardableResult
    public static func __explore<Output>(
        _ gen: ReflectiveGenerator<Output>,
        settings: [ExploreSettings],
        scorer: @Sendable @escaping (Output) -> Double,
        sourceCode: String?,
        fileID: StaticString = #fileID,
        filePath: StaticString = #filePath,
        line: UInt = #line,
        column: UInt = #column,
        property: @Sendable @escaping (Output) -> Bool,
    ) -> Output? {
        var samplingBudget: UInt64 = 10000
        var seed: UInt64?
        var reductionConfig: TCRBudget = .fast
        var suppressIssueReporting = false
        var poolCapacity = 256
        var generateRatio = 0.2
        var useKleisliReducer = false

        for setting in settings {
            switch setting {
            case let .samplingBudget(n):
                samplingBudget = n
            case let .replay(s):
                seed = s
            case let .reductionBudget(config):
                reductionConfig = config
            case .suppressIssueReporting:
                suppressIssueReporting = true
            case let .poolCapacity(n):
                poolCapacity = n
            case let .generateRatio(r):
                generateRatio = r
            case .useKleisliReducer:
                useKleisliReducer = true
            }
        }

        var runner = ExploreRunner(
            gen: gen,
            property: property,
            samplingBudget: samplingBudget,
            reductionConfig: reductionConfig,
            useKleisliReducer: useKleisliReducer,
            poolCapacity: poolCapacity,
            generateRatio: generateRatio,
            seed: seed,
            scorer: scorer,
        )
        let actualSeed = runner.baseSeed

        let result = runner.run()

        switch result {
        case let .failure(counterexample, shrunkSequence, original, iteration):
            let failure = PropertyTestFailure(
                counterexample: counterexample,
                original: original,
                sourceCode: sourceCode,
                seed: actualSeed,
                iteration: Int(iteration),
                samplingBudget: samplingBudget,
                blueprint: shrunkSequence.shortString,
                propertyInvocations: nil,
            )
            let rendered = failure.render(format: ExhaustLog.configuration.format)
            ExhaustLog.error(
                category: .propertyTest,
                event: "explore_property_failed",
                rendered,
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
            return counterexample

        case let .unshrunkFailure(counterexample, iteration):
            let failure = PropertyTestFailure(
                counterexample: counterexample,
                original: nil as Output?,
                sourceCode: sourceCode,
                seed: actualSeed,
                iteration: Int(iteration),
                samplingBudget: samplingBudget,
                blueprint: nil,
                propertyInvocations: nil,
            )
            let rendered = failure.render(format: ExhaustLog.configuration.format)
            ExhaustLog.error(
                category: .propertyTest,
                event: "explore_property_failed",
                rendered,
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
            return counterexample

        case let .passed(iterations, poolSize):
            var passMetadata = [
                "iterations": "\(iterations)",
                "poolSize": "\(poolSize)",
            ]
            if let sourceCode {
                passMetadata["source"] = sourceCode
            }
            ExhaustLog.notice(
                category: .propertyTest,
                event: "explore_property_passed",
                metadata: passMetadata,
            )
            return nil
        }
    }

    // MARK: - Extraction

    /// Generates a single value from a generator. Runtime target of `#extract` expansion.
    public static func __extract<Output>(
        _ gen: ReflectiveGenerator<Output>,
        seed: UInt64?,
    ) -> Output {
        var interpreter = ValueInterpreter(gen, seed: seed, maxRuns: 1, sizeOverride: 50)
        guard let value = try? interpreter.next() else {
            fatalError("#extract: generator produced no values")
        }
        return value
    }

    /// Generates an array of values from a generator. Runtime target of `#extract` expansion.
    public static func __extractArray<Output>(
        _ gen: ReflectiveGenerator<Output>,
        count: UInt64,
        seed: UInt64?,
    ) -> [Output] {
        var interpreter = ValueInterpreter(gen, seed: seed, maxRuns: count)
        var results: [Output] = []
        while let value = try? interpreter.next() {
            results.append(value)
        }
        return results
    }

    // MARK: - Examination

    /// Validates a generator's reflection, replay, and health. Runtime target of `#examine` expansion.
    @discardableResult
    public static func __examine(
        _ gen: ReflectiveGenerator<some Any>,
        samples: Int,
        seed: UInt64?,
        fileID: StaticString,
        filePath: StaticString,
        line: UInt,
        column: UInt,
    ) -> ValidationReport {
        gen.validate(
            samples: samples,
            seed: seed,
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column,
        )
    }

    // MARK: - Reflecting

    // swiftlint:disable:next function_parameter_count
    private static func __reduceReflected<Output>(
        _ gen: ReflectiveGenerator<Output>,
        value: Output,
        reductionConfig: TCRBudget,
        useKleisliReducer: Bool,
        suppressIssueReporting: Bool,
        sourceCode: String?,
        fileID: StaticString,
        filePath: StaticString,
        line: UInt,
        column: UInt,
        property: @Sendable (Output) -> Bool,
    ) throws -> Output? {
        guard property(value) == false else {
            let message = "reflecting: value passes the property — reduction requires a failing value"
            ExhaustLog.error(
                category: .propertyTest,
                event: "reflecting_value_passes",
                message,
            )
            if !suppressIssueReporting {
                reportIssue(
                    message,
                    fileID: fileID,
                    filePath: filePath,
                    line: line,
                    column: column,
                )
            }
            return nil
        }

        guard let tree = try Interpreters.reflect(gen, with: value) else {
            let message = "reflecting: could not reflect value into choice tree"
            ExhaustLog.error(
                category: .propertyTest,
                event: "reflecting_failed",
                message,
            )
            if !suppressIssueReporting {
                reportIssue(
                    message,
                    fileID: fileID,
                    filePath: filePath,
                    line: line,
                    column: column,
                )
            }
            return nil
        }

        var propertyInvocationCount = 0
        let countingProperty: (Output) -> Bool = { value in
            propertyInvocationCount += 1
            return property(value)
        }
        if let (shrunkSequence, shrunkValue) = try Interpreters.dispatchReduce(
            gen: gen,
            tree: tree,
            config: reductionConfig,
            useKleisli: useKleisliReducer,
            property: countingProperty,
        ) {
            let failure = PropertyTestFailure(
                counterexample: shrunkValue,
                original: value,
                sourceCode: sourceCode,
                seed: nil,
                iteration: 1,
                samplingBudget: 1,
                blueprint: shrunkSequence.shortString,
                propertyInvocations: propertyInvocationCount,
            )
            let rendered = failure.render(format: ExhaustLog.configuration.format)
            ExhaustLog.error(
                category: .propertyTest,
                event: "reflecting_reduced",
                rendered,
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

        // Reflection succeeded but reduction could not improve — return original
        let failure = PropertyTestFailure(
            counterexample: value,
            original: nil as Output?,
            sourceCode: sourceCode,
            seed: nil,
            iteration: 1,
            samplingBudget: 1,
            blueprint: nil,
            propertyInvocations: propertyInvocationCount,
        )
        let rendered = failure.render(format: ExhaustLog.configuration.format)
        ExhaustLog.error(
            category: .propertyTest,
            event: "reflecting_unreduced",
            rendered,
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
        return value
    }
}
