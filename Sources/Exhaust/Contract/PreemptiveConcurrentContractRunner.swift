import ExhaustCore
import Foundation
import IssueReporting

// MARK: - Runner Entry Point

/// Runs a preemptive concurrent contract test for the given sync specification type.
///
/// Dispatches commands across real GCD threads and uses the spec's ``ConcurrentContractSpec/oracleCheck(_:)`` to verify consistency with sequential behavior. Non-deterministic scheduling means the same seed does not guarantee the same interleaving — bug detection is probabilistic, relying on repetition across the sampling budget.
@discardableResult
public func __runPreemptiveConcurrentContract<Spec: ConcurrentContractSpec>(
    _ specType: Spec.Type,
    settings: [ConcurrentContractSettings],
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
) -> ContractResult<Spec>? {
    let config: ResolvedConcurrentConfig
    switch ResolvedConcurrentConfig.parse(settings) {
    case let .success(resolved):
        config = resolved
    case let .invalidReplaySeed(seed):
        reportIssue(
            "Invalid replay seed: \(seed)",
            fileID: fileID, filePath: filePath, line: line, column: column
        )
        return nil
    }

    let runStartNanos = DispatchTime.now().uptimeNanoseconds
    var report = ExhaustReport()
    report.seed = config.seed

    defer {
        let elapsedNanos = DispatchTime.now().uptimeNanoseconds - runStartNanos
        report.totalMilliseconds = Double(elapsedNanos) / 1_000_000
        config.onReportClosure?(report)
    }

    let commandGen = Spec.commandGenerator.gen
    let commandLimit = config.commandLimit ?? 8
    let taggedCommandGen = zipScheduleMarker(onto: commandGen, concurrencyLevel: config.concurrencyLevel)
    let sequenceGen = Gen.arrayOf(
        taggedCommandGen,
        within: 1 ... UInt64(commandLimit),
        scaling: .constant
    )

    let samplingBudget = config.budget.samplingBudget
    var interpreter = ValueAndChoiceTreeInterpreter(
        sequenceGen,
        materializePicks: true,
        seed: config.seed,
        maxRuns: samplingBudget
    )
    let actualSeed = interpreter.baseSeed

    let check = PreemptiveChecker<Spec>()
    var iteration = 0

    while let (taggedCommands, tree) = try? interpreter.next() {
        iteration += 1
        if check.execute(taggedCommands) == false {
            let reductionResult = check.reduce(
                generator: sequenceGen,
                tree: tree,
                output: taggedCommands,
                repetitions: 10
            )
            let reduced = reductionResult.output

            let commands = reduced.map(\.1)

            var laneCounts: [UInt8: Int] = [:]
            let trace = reduced.enumerated().map { index, tagged in
                let (marker, command) = tagged
                if marker.isPrefix {
                    return TraceStep(
                        index: index + 1,
                        command: "\(command) (prefix)",
                        outcome: .ok
                    )
                } else {
                    let laneLabel = marker.description.uppercased()
                    laneCounts[marker.rawValue, default: 0] += 1
                    let laneIndex = laneCounts[marker.rawValue]!
                    return TraceStep(
                        index: index + 1,
                        command: "\(laneIndex)\(laneLabel) \(command) (completed)",
                        outcome: .ok
                    )
                }
            }

            let oracleSpec = Spec()
            for (_, command) in reduced {
                try? oracleSpec.run(command)
            }

            let result = ContractResult<Spec>(
                commands: commands,
                trace: trace,
                systemUnderTest: oracleSpec.systemUnderTest,
                seed: actualSeed,
                discoveryMethod: .randomSampling
            )

            report.setInvocations(coverage: 0, randomSampling: iteration, reduction: reductionResult.propertyInvocations)
            report.applyReductionStats(reductionResult.stats)

            if config.suppressIssueReporting == false {
                var failureContext = FailureContext()
                failureContext.specName = "\(Spec.self)"
                failureContext.discoveryMethod = .randomSampling
                failureContext.seed = actualSeed
                failureContext.iteration = iteration
                failureContext.budget = samplingBudget
                failureContext.sequencesTested = iteration
                failureContext.reductionInvocations = reductionResult.propertyInvocations
                failureContext.originalCount = taggedCommands.count
                failureContext.oracleDescription = "Expected state (from sequential replay):\n  \(oracleSpec.sutDescription)"
                let message = renderFailure(reduced, trace: trace, context: failureContext)
                reportIssue(message, fileID: fileID, filePath: filePath, line: line, column: column)
            }

            return result
        }
    }

    report.setInvocations(coverage: 0, randomSampling: iteration, reduction: 0)
    return nil
}

// MARK: - Checker

/// Encapsulates concurrent execution, oracle comparison, and three-pass reduction for a ``ConcurrentContractSpec``.
private struct PreemptiveChecker<Spec: ConcurrentContractSpec> {

    /// Executes a tagged command sequence with real GCD concurrency and checks invariants + oracle.
    ///
    /// Returns `true` if the execution passes. Returns `false` if invariants fail or the oracle detects divergence from sequential behavior.
    func execute(_ taggedCommands: [(ScheduleMarker, Spec.Command)]) -> Bool {
        let concurrentSpec = Spec()
        let sequentialSpec = Spec()

        let prefixCommands = taggedCommands.filter { $0.0.isPrefix }
        let concurrentCommands = taggedCommands.filter { $0.0.isPrefix == false }

        for (_, command) in prefixCommands {
            try? concurrentSpec.run(command)
            try? sequentialSpec.run(command)
        }

        for (_, command) in concurrentCommands {
            try? sequentialSpec.run(command)
        }

        let laneGroups = Dictionary(grouping: concurrentCommands) { $0.0.rawValue }
        let group = DispatchGroup()
        for (_, laneCommands) in laneGroups {
            group.enter()
            DispatchQueue.global().async {
                for (_, command) in laneCommands {
                    try? concurrentSpec.run(command)
                }
                group.leave()
            }
        }
        group.wait()

        do {
            try concurrentSpec.checkInvariants()
        } catch {
            return false
        }

        return concurrentSpec.oracleCheck(sequentialSpec.systemUnderTest)
    }

    struct ReductionResult {
        let output: [(ScheduleMarker, Spec.Command)]
        let propertyInvocations: Int
        let stats: ReductionStats
    }

    /// Best-effort three-pass reduction. Returns the best result found, which may be the original if reduction stalled.
    func reduce(
        generator: Generator<[(ScheduleMarker, Spec.Command)]>,
        tree: ChoiceTree,
        output: [(ScheduleMarker, Spec.Command)],
        repetitions: Int
    ) -> ReductionResult {
        var propertyInvocations = 0
        let property: ([(ScheduleMarker, Spec.Command)]) -> Bool = { taggedCommands in
            for _ in 0 ..< repetitions {
                propertyInvocations += 1
                if self.execute(taggedCommands) == false {
                    return false
                }
            }
            return true
        }

        let structural: Set<EncoderName> = [.deletion, .migration, .substitution]
        let cosmetic = Set(EncoderName.allCases).subtracting(structural).subtracting([.laneCollapse])

        var currentOutput = output
        var currentTree = tree
        var aggregateStats = ReductionStats()

        if let result = try? Interpreters.choiceGraphReduceCollectingStats(
            gen: generator,
            tree: currentTree,
            output: currentOutput,
            config: .init(maxStalls: 2, wallClockDeadlineNanoseconds: 10_000_000_000, enabledEncoders: [.laneCollapse]),
            property: property
        ) {
            aggregateStats.merge(result.stats)
            if let (sequence, reduced) = result.reduced {
                currentOutput = reduced
                if case let .success(_, freshTree, _) = Materializer.materialize(
                    generator, prefix: sequence, mode: .exact, fallbackTree: currentTree, materializePicks: true
                ) {
                    currentTree = freshTree
                }
            }
        }

        if let result = try? Interpreters.choiceGraphReduceCollectingStats(
            gen: generator,
            tree: currentTree,
            output: currentOutput,
            config: .init(maxStalls: 2, wallClockDeadlineNanoseconds: 30_000_000_000, enabledEncoders: structural),
            property: property
        ) {
            aggregateStats.merge(result.stats)
            if let (sequence, reduced) = result.reduced {
                currentOutput = reduced
                if case let .success(_, freshTree, _) = Materializer.materialize(
                    generator, prefix: sequence, mode: .exact, fallbackTree: currentTree, materializePicks: true
                ) {
                    currentTree = freshTree
                }
            }
        }

        if let result = try? Interpreters.choiceGraphReduceCollectingStats(
            gen: generator,
            tree: currentTree,
            output: currentOutput,
            config: .init(maxStalls: 1, wallClockDeadlineNanoseconds: 5_000_000_000, enabledEncoders: cosmetic),
            property: property
        ) {
            aggregateStats.merge(result.stats)
            if let (_, reduced) = result.reduced {
                currentOutput = reduced
            }
        }

        return ReductionResult(output: currentOutput, propertyInvocations: propertyInvocations, stats: aggregateStats)
    }
}

// MARK: - Async Entry Point

/// Runs a preemptive concurrent contract test for the given async specification type.
///
/// Dispatches commands across real GCD threads and bridges async command execution via Task+semaphore. This catches races in synchronous primitives (locks, dispatch queues, atomics) hidden behind async facades — the cooperative runner's deterministic interleaving only reaches `await` suspension points.
///
/// The outer loop runs on a GCD thread (via ``__ExhaustRuntime/dispatchToGCD(_:)``) to avoid starving the cooperative pool during parallel test runs. Issue reporting is deferred to the async return context where Swift Testing's task-locals are available.
@discardableResult
public func __runPreemptiveConcurrentContractAsync<Spec: AsyncConcurrentContractSpec>(
    _ specType: Spec.Type,
    settings: [ConcurrentContractSettings],
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
) async -> ContractResult<Spec>? {
    let config: ResolvedConcurrentConfig
    switch ResolvedConcurrentConfig.parse(settings) {
    case let .success(resolved):
        config = resolved
    case let .invalidReplaySeed(seed):
        reportIssue(
            "Invalid replay seed: \(seed)",
            fileID: fileID, filePath: filePath, line: line, column: column
        )
        return nil
    }

    let outcome: (ContractResult<Spec>?, [String], ExhaustReport) = await __ExhaustRuntime.dispatchToGCD {
        () -> (ContractResult<Spec>?, [String], ExhaustReport) in
        let runStartNanos = DispatchTime.now().uptimeNanoseconds
        var report = ExhaustReport()
        report.seed = config.seed
        var deferredIssues: [String] = []

        func finalizeReport() {
            let elapsedNanos = DispatchTime.now().uptimeNanoseconds - runStartNanos
            report.totalMilliseconds = Double(elapsedNanos) / 1_000_000
        }

        let commandGen = Spec.commandGenerator.gen
        let commandLimit = config.commandLimit ?? 8
        let taggedCommandGen = zipScheduleMarker(onto: commandGen, concurrencyLevel: config.concurrencyLevel)
        let sequenceGen = Gen.arrayOf(
            taggedCommandGen,
            within: 1 ... UInt64(commandLimit),
            scaling: .constant
        )

        let samplingBudget = config.budget.samplingBudget
        var interpreter = ValueAndChoiceTreeInterpreter(
            sequenceGen,
            materializePicks: true,
            seed: config.seed,
            maxRuns: samplingBudget
        )
        let actualSeed = interpreter.baseSeed

        let check = AsyncPreemptiveChecker<Spec>()
        var iteration = 0

        while let (taggedCommands, tree) = try? interpreter.next() {
            iteration += 1
            if check.execute(taggedCommands) == false {
                let reductionResult = check.reduce(
                    generator: sequenceGen,
                    tree: tree,
                    output: taggedCommands,
                    repetitions: 10
                )
                let reduced = reductionResult.output

                let commands = reduced.map(\.1)

                var laneCounts: [UInt8: Int] = [:]
                let trace = reduced.enumerated().map { index, tagged in
                    let (marker, command) = tagged
                    if marker.isPrefix {
                        return TraceStep(
                            index: index + 1,
                            command: "\(command) (prefix)",
                            outcome: .ok
                        )
                    } else {
                        let laneLabel = marker.description.uppercased()
                        laneCounts[marker.rawValue, default: 0] += 1
                        let laneIndex = laneCounts[marker.rawValue]!
                        return TraceStep(
                            index: index + 1,
                            command: "\(laneIndex)\(laneLabel) \(command) (completed)",
                            outcome: .ok
                        )
                    }
                }

                let oracleSpec = Spec()
                check.runSequentially(reduced.map(\.1), on: oracleSpec)

                let result = ContractResult<Spec>(
                    commands: commands,
                    trace: trace,
                    systemUnderTest: oracleSpec.systemUnderTest,
                    seed: actualSeed,
                    discoveryMethod: .randomSampling
                )

                report.setInvocations(coverage: 0, randomSampling: iteration, reduction: reductionResult.propertyInvocations)
                report.applyReductionStats(reductionResult.stats)

                if config.suppressIssueReporting == false {
                    var failureContext = FailureContext()
                    failureContext.specName = "\(Spec.self)"
                    failureContext.discoveryMethod = .randomSampling
                    failureContext.seed = actualSeed
                    failureContext.iteration = iteration
                    failureContext.budget = samplingBudget
                    failureContext.sequencesTested = iteration
                    failureContext.reductionInvocations = reductionResult.propertyInvocations
                    failureContext.originalCount = taggedCommands.count
                    failureContext.oracleDescription = "Expected state (from sequential replay):\n  \(oracleSpec.sutDescription)"
                    let message = renderFailure(reduced, trace: trace, context: failureContext)
                    deferredIssues.append(message)
                }

                finalizeReport()
                return (result, deferredIssues, report)
            }
        }

        report.setInvocations(coverage: 0, randomSampling: iteration, reduction: 0)
        finalizeReport()
        return (nil, deferredIssues, report)
    }
    config.onReportClosure?(outcome.2)
    for issue in outcome.1 {
        reportIssue(issue, fileID: fileID, filePath: filePath, line: line, column: column)
    }
    return outcome.0
}

// MARK: - Async Checker

/// Encapsulates concurrent execution, oracle comparison, and three-pass reduction for an ``AsyncConcurrentContractSpec``.
///
/// Bridges async command execution to GCD threads via Task+semaphore. Each lane gets a real OS thread, and within that thread async commands are driven synchronously — the cooperative pool handles the Task's continuations while the GCD thread blocks on the semaphore. This provides real thread-level preemption for synchronous primitives (locks, dispatch queues) hidden behind async facades.
private struct AsyncPreemptiveChecker<Spec: AsyncConcurrentContractSpec> {

    /// Executes a tagged command sequence with real GCD concurrency and checks invariants + oracle.
    ///
    /// Prefix and sequential commands are bridged through a single Task+semaphore. Concurrent commands are dispatched to real GCD threads (one per lane), each bridging async execution independently.
    func execute(_ taggedCommands: [(ScheduleMarker, Spec.Command)]) -> Bool {
        let concurrentSpec = Spec()
        let sequentialSpec = Spec()

        let prefixCommands = taggedCommands.filter { $0.0.isPrefix }
        let concurrentCommands = taggedCommands.filter { $0.0.isPrefix == false }

        runSequentially(prefixCommands.map(\.1), on: concurrentSpec)
        runSequentially(prefixCommands.map(\.1), on: sequentialSpec)
        runSequentially(concurrentCommands.map(\.1), on: sequentialSpec)

        let laneGroups = Dictionary(grouping: concurrentCommands) { $0.0.rawValue }
        let group = DispatchGroup()
        for (_, laneCommands) in laneGroups {
            group.enter()
            DispatchQueue.global().async {
                let semaphore = DispatchSemaphore(value: 0)
                nonisolated(unsafe) let spec = concurrentSpec
                Task { @Sendable in
                    for (_, command) in laneCommands {
                        try? await spec.run(command)
                    }
                    semaphore.signal()
                }
                semaphore.wait()
                group.leave()
            }
        }
        group.wait()

        let invariantsPassed: Bool = {
            let semaphore = DispatchSemaphore(value: 0)
            let result = SendableBox(true)
            nonisolated(unsafe) let spec = concurrentSpec
            Task { @Sendable in
                do {
                    try await spec.checkInvariants()
                } catch {
                    result.value = false
                }
                semaphore.signal()
            }
            semaphore.wait()
            return result.value
        }()

        if invariantsPassed == false {
            return false
        }

        return concurrentSpec.oracleCheck(sequentialSpec.systemUnderTest)
    }

    /// Runs commands sequentially on a spec, bridging async execution via Task+semaphore.
    func runSequentially(_ commands: [Spec.Command], on spec: Spec) {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) let spec = spec
        Task { @Sendable in
            for command in commands {
                try? await spec.run(command)
            }
            semaphore.signal()
        }
        semaphore.wait()
    }

    struct ReductionResult {
        let output: [(ScheduleMarker, Spec.Command)]
        let propertyInvocations: Int
        let stats: ReductionStats
    }

    /// Best-effort three-pass reduction, identical structure to the sync variant.
    func reduce(
        generator: Generator<[(ScheduleMarker, Spec.Command)]>,
        tree: ChoiceTree,
        output: [(ScheduleMarker, Spec.Command)],
        repetitions: Int
    ) -> ReductionResult {
        var propertyInvocations = 0
        let property: ([(ScheduleMarker, Spec.Command)]) -> Bool = { taggedCommands in
            for _ in 0 ..< repetitions {
                propertyInvocations += 1
                if self.execute(taggedCommands) == false {
                    return false
                }
            }
            return true
        }

        let structural: Set<EncoderName> = [.deletion, .migration, .substitution]
        let cosmetic = Set(EncoderName.allCases).subtracting(structural).subtracting([.laneCollapse])

        var currentOutput = output
        var currentTree = tree
        var aggregateStats = ReductionStats()

        if let result = try? Interpreters.choiceGraphReduceCollectingStats(
            gen: generator,
            tree: currentTree,
            output: currentOutput,
            config: .init(maxStalls: 2, wallClockDeadlineNanoseconds: 10_000_000_000, enabledEncoders: [.laneCollapse]),
            property: property
        ) {
            aggregateStats.merge(result.stats)
            if let (sequence, reduced) = result.reduced {
                currentOutput = reduced
                if case let .success(_, freshTree, _) = Materializer.materialize(
                    generator, prefix: sequence, mode: .exact, fallbackTree: currentTree, materializePicks: true
                ) {
                    currentTree = freshTree
                }
            }
        }

        if let result = try? Interpreters.choiceGraphReduceCollectingStats(
            gen: generator,
            tree: currentTree,
            output: currentOutput,
            config: .init(maxStalls: 2, wallClockDeadlineNanoseconds: 30_000_000_000, enabledEncoders: structural),
            property: property
        ) {
            aggregateStats.merge(result.stats)
            if let (sequence, reduced) = result.reduced {
                currentOutput = reduced
                if case let .success(_, freshTree, _) = Materializer.materialize(
                    generator, prefix: sequence, mode: .exact, fallbackTree: currentTree, materializePicks: true
                ) {
                    currentTree = freshTree
                }
            }
        }

        if let result = try? Interpreters.choiceGraphReduceCollectingStats(
            gen: generator,
            tree: currentTree,
            output: currentOutput,
            config: .init(maxStalls: 1, wallClockDeadlineNanoseconds: 5_000_000_000, enabledEncoders: cosmetic),
            property: property
        ) {
            aggregateStats.merge(result.stats)
            if let (_, reduced) = result.reduced {
                currentOutput = reduced
            }
        }

        return ReductionResult(output: currentOutput, propertyInvocations: propertyInvocations, stats: aggregateStats)
    }
}
