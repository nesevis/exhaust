import ExhaustCore
import Testing
@testable import Exhaust

@Suite("ContractMachine phase transitions", .tags(.contract))
struct ContractMachineTests {
    @Test("Empty source list finalizes immediately")
    func emptySourceListFinalizesImmediately() {
        var machine = makeMachine(sources: [])
        let first = machine.next()
        #expect(first == .sourceExhausted)
        #expect(machine.next() == nil)
        #expect(machine.result == nil)
    }

    @Test("Source that returns nil advances to next source")
    func sourceReturningNilAdvancesToNextSource() {
        let emptySource = AnyContractCandidateSource<StubCommand> { nil }
        var hitSecond = false
        let secondSource = AnyContractCandidateSource<StubCommand> {
            hitSecond = true
            return nil
        }
        var machine = makeMachine(sources: [emptySource, secondSource])

        #expect(machine.next() == .sourceExhausted)
        #expect(hitSecond == false)
        #expect(machine.next() == .sourceExhausted)
        #expect(hitSecond)
    }

    @Test("Source error records deferred issue and advances")
    func sourceErrorRecordsDeferredIssueAndAdvances() {
        let failingSource = AnyContractCandidateSource<StubCommand> {
            throw StubError.generatorFailed
        }
        let context = makeContext()
        var machine = makeMachine(context: context, sources: [failingSource])

        let transition = machine.next()
        if case let .sourceError(message) = transition {
            #expect(message.contains("Generator failed"))
        } else {
            Issue.record("Expected .sourceError, got \(String(describing: transition))")
        }
        #expect(context.state.deferredIssues.count == 1)
    }

    @Test("Candidate found transitions through full pipeline to assembled")
    func candidateFoundTransitionsThroughFullPipeline() {
        let candidate = makeCandidate(commands: [(.prefix, .increment)])
        let source = AnyContractCandidateSource<StubCommand>.once { candidate }
        var machine = makeMachine(sources: [source])

        var transitions: [String] = []
        while let transition = machine.next() {
            transitions.append(label(transition))
        }

        #expect(transitions.contains("candidateFound"))
        #expect(transitions.contains("pruned"))
        #expect(transitions.contains("reduced"))
        #expect(transitions.contains("statsRecorded"))
        #expect(transitions.contains("assembled"))
        #expect(machine.result != nil)
        #expect(machine.result != nil)
    }

    @Test("Reduction invocations are tracked in report")
    func reductionInvocationsAreTrackedInReport() {
        let candidate = makeCandidate(commands: [(.prefix, .increment), (.prefix, .increment)])
        let source = AnyContractCandidateSource<StubCommand>.once { candidate }
        let context = makeContext()
        var machine = makeMachine(context: context, sources: [source])

        while machine.next() != nil {}

        #expect(context.state.report.propertyInvocations > 0)
    }

    @Test("Each source's invocations are attributed to its bucket, including a passing source")
    func sourceInvocationsAttributedPerBucket() {
        let context = makeContext()
        let coverageSource = AnyContractCandidateSource<StubCommand>(discoveryMethod: .coverage) {
            context.invocationCounter.value += 5
            return nil
        }
        let samplingSource = AnyContractCandidateSource<StubCommand>(discoveryMethod: .randomSampling) {
            context.invocationCounter.value += 3
            return makeCandidate(commands: [(.prefix, .increment)], discoveryMethod: .randomSampling)
        }
        var machine = makeMachine(context: context, sources: [coverageSource, samplingSource])

        while machine.next() != nil {}

        // The coverage source passed but its 5 probes are still counted; sampling's 3 land in their own bucket; reduction adds the StubBackend's 2.
        #expect(context.state.report.coverageInvocations == 5)
        #expect(context.state.report.randomSamplingInvocations == 3)
        #expect(context.state.report.reductionInvocations == 2)
        #expect(context.state.report.propertyInvocations == 10)
    }

    @Test("A sampling-only run attributes no wall time to the coverage phase")
    func samplingOnlyRunHasNoCoverageTime() {
        let context = makeContext()
        let samplingSource = AnyContractCandidateSource<StubCommand>(discoveryMethod: .randomSampling) {
            makeCandidate(commands: [(.prefix, .increment)], discoveryMethod: .randomSampling)
        }
        var machine = makeMachine(context: context, sources: [samplingSource])

        while machine.next() != nil {}

        #expect(context.state.report.coverageMilliseconds == 0)
    }

    @Test("Report seed comes from the sampling source even when the run passes")
    func reportSeedComesFromSamplingSource() {
        var deliveredReport: ExhaustReport?
        let context = makeContext(config: makeConfig(onReport: { deliveredReport = $0 }))
        let samplingSource = AnyContractCandidateSource<StubCommand>(discoveryMethod: .randomSampling, reportedSeed: 99) {
            nil
        }
        var machine = makeMachine(context: context, sources: [samplingSource])

        while machine.next() != nil {}

        #expect(deliveredReport?.seed == 99)
    }

    @Test("Finalize delivers report to onReport closure")
    func finalizeDeliversReportToOnReportClosure() {
        var deliveredReport: ExhaustReport?
        let config = makeConfig(onReport: { deliveredReport = $0 })
        var machine = makeMachine(config: config, sources: [])

        while machine.next() != nil {}

        #expect(deliveredReport != nil)
    }

    @Test("Multiple sources are tried in order until one produces a candidate")
    func multipleSourcesTriedInOrder() {
        var sourceOrder: [Int] = []
        let emptyFirst = AnyContractCandidateSource<StubCommand> {
            sourceOrder.append(1)
            return nil
        }
        let emptySecond = AnyContractCandidateSource<StubCommand> {
            sourceOrder.append(2)
            return nil
        }
        let failingThird = AnyContractCandidateSource<StubCommand>.once {
            sourceOrder.append(3)
            return makeCandidate(commands: [(.prefix, .increment)])
        }
        var machine = makeMachine(sources: [emptyFirst, emptySecond, failingThird])

        while machine.next() != nil {}

        #expect(sourceOrder == [1, 2, 3])
        #expect(machine.result != nil)
    }

    @Test("Pipeline run method drives machine to completion")
    func pipelineRunDrivesMachineToCompletion() {
        let pipeline = makePipeline(propertyPasses: false)
        let config = makeConfig()
        let (result, issues) = pipeline.run(config: config)
        #expect(result != nil)
        #expect(issues.isEmpty == false)
    }

    @Test("Pipeline run returns nil when property passes")
    func pipelineRunReturnsNilWhenPropertyPasses() {
        let pipeline = makePipeline(propertyPasses: true)
        let config = makeConfig()
        let (result, issues) = pipeline.run(config: config)
        #expect(result == nil)
        #expect(issues.isEmpty)
    }
}

// MARK: - Coverage Source Selection

@Suite("Contract coverage source selection", .tags(.contract))
struct ContractCoverageSourceSelectionTests {
    /// Whenever coverage runs, no replay target may be set. A replay (sampling seed, coverage row, or iteration) must reproduce its targeted failure, not launch a fresh full coverage sweep that could surface an unrelated failure and mask a stale regression seed.
    @Test("A replay never also triggers a full coverage sweep")
    func replayNeverTriggersCoverageSweep() {
        let configGen = #gen(
            .int(in: 0 ... 1_000_000).optional(),
            .int(in: 0 ... 100).optional(),
            .int(in: 1 ... 100).optional(),
            .int(in: 0 ... 400)
        ) { seedSource, coverageReplayRow, replayIteration, coverageBudget in
            var config = ResolvedConcurrentConfig()
            config.seed = seedSource.map { UInt64($0) }
            config.coverageReplayRow = coverageReplayRow
            config.replayIteration = replayIteration
            config.budget = .custom(coverage: coverageBudget, sampling: 200)
            return config
        }
        #exhaust(configGen) { config in
            config.shouldRunCoverage == false
                || (config.seed == nil && config.coverageReplayRow == nil && config.replayIteration == nil)
        }
    }

    /// Pins the other direction so the invariant above is not vacuously satisfied by an implementation that never runs coverage.
    @Test("A fresh run with budget enables the coverage sweep")
    func freshRunEnablesCoverage() {
        var config = ResolvedConcurrentConfig()
        config.budget = .custom(coverage: 200, sampling: 200)
        #expect(config.shouldRunCoverage)
    }
}

// MARK: - Prefix-First Ordering

@Suite("prefixFirstOrder", .tags(.contract))
struct PrefixFirstOrderTests {
    private static let taggedCommandGen = #gen(
        .int(in: 0 ... 3),
        .element(from: [StubCommand.increment, .decrement])
    ) { marker, command in
        (ScheduleMarker(rawValue: UInt8(marker)), command)
    }

    @Test("Stable partition: prefixes first, both subsequences preserve input order")
    func stablePartition() {
        #exhaust(Self.taggedCommandGen.array(length: 0 ... 8)) { input in
            let result = input.prefixFirstOrder()
            let prefixCount = input.count(where: { $0.0.isPrefix })

            let allPrefixesFirst = result.prefix(prefixCount).allSatisfy(\.0.isPrefix)
            let allLanesAfter = result.dropFirst(prefixCount).allSatisfy { $0.0.isPrefix == false }
            #expect(allPrefixesFirst)
            #expect(allLanesAfter)

            let resultPrefixCommands = result.prefix(prefixCount).map(\.1)
            let inputPrefixCommands = input.filter(\.0.isPrefix).map(\.1)
            #expect(resultPrefixCommands == inputPrefixCommands)

            let resultLaneDescriptions = result.dropFirst(prefixCount).map { "\($0.0)\($0.1)" }
            let inputLaneDescriptions = input.filter { $0.0.isPrefix == false }.map { "\($0.0)\($0.1)" }
            #expect(resultLaneDescriptions == inputLaneDescriptions)
        }
    }
}

// MARK: - Stub Types

private enum StubCommand: CustomStringConvertible {
    case increment
    case decrement

    var description: String {
        switch self {
            case .increment: "increment"
            case .decrement: "decrement"
        }
    }
}

private enum StubError: Error {
    case generatorFailed
}

private struct StubSpec: ContractSpecBase {
    typealias Command = StubCommand
    typealias SystemUnderTest = Int

    static var commandGenerator: ReflectiveGenerator<StubCommand> {
        #gen(.element(from: [StubCommand.increment, StubCommand.decrement]))
    }

    static var executionModel: ExecutionModel {
        .sequential
    }

    var systemUnderTest: Int {
        0
    }

    func failureDescription() -> String? {
        nil
    }

    init() {}
}

private struct StubBackend: ContractBackend {
    typealias Spec = StubSpec

    var probeResult: ProbeOutcome = .fail

    func probe(
        _: [(ScheduleMarker, StubCommand)],
        context _: ContractRunContext<StubSpec>
    ) -> ProbeOutcome {
        probeResult
    }

    func reduce(
        taggedCommands: [(ScheduleMarker, StubCommand)],
        tree _: ChoiceTree,
        context: ContractRunContext<StubSpec>
    ) -> ContractReduction<StubCommand> {
        // Simulate two reduction probes so the machine's reduction-invocation delta is observable.
        context.invocationCounter.value += 2
        return ContractReduction(finalInput: taggedCommands, stats: nil, timedOut: false)
    }

    func buildResult(
        reduced: [(ScheduleMarker, StubCommand)],
        originalCommands: [StubCommand]?,
        seed: UInt64?,
        iteration _: Int,
        discoveryMethod: ContractDiscoveryMethod,
        context _: ContractRunContext<StubSpec>
    ) -> (result: ContractResult<StubSpec>, issueMessage: String) {
        let result = ContractResult<StubSpec>(
            commands: reduced.map(\.1),
            originalCommands: originalCommands,
            trace: [],
            systemUnderTest: 0,
            seed: seed,
            replaySeed: nil,
            discoveryMethod: discoveryMethod
        )
        return (result, "stub failure")
    }
}

// MARK: - Helpers

private func stubSequenceGen() -> Generator<[(ScheduleMarker, StubCommand)]> {
    StubSpec.commandGenerator.array(length: 0 ... 5, scaling: .constant).gen.map { commands in
        commands.map { (ScheduleMarker.prefix, $0) }
    }
}

private func makeCandidate(
    commands: [(ScheduleMarker, StubCommand)],
    discoveryMethod: ContractDiscoveryMethod = .coverage,
    seed: UInt64 = 0
) -> ContractCandidate<StubCommand> {
    ContractCandidate(
        taggedCommands: commands,
        tree: .just,
        sequenceGen: stubSequenceGen(),
        seed: seed,
        iteration: 1,
        discoveryMethod: discoveryMethod
    )
}

private func makeConfig(
    onReport: ((ExhaustReport) -> Void)? = nil
) -> ResolvedConcurrentConfig {
    var config = ResolvedConcurrentConfig()
    config.budget = .custom(coverage: 0, sampling: 10)
    config.suppressIssueReporting = true
    config.onReportClosure = onReport
    return config
}

private func makeContext(
    config: ResolvedConcurrentConfig? = nil
) -> ContractRunContext<StubSpec> {
    let resolved = config ?? makeConfig()
    return ContractRunContext<StubSpec>(
        config: resolved,
        sequenceGen: stubSequenceGen(),
        commandGen: StubSpec.commandGenerator.gen,
        commandLimit: 5,
        identifySkips: { _ in [] },
        fileID: #fileID,
        filePath: #filePath,
        line: #line,
        column: #column
    )
}

private func makeMachine(
    config: ResolvedConcurrentConfig? = nil,
    context: ContractRunContext<StubSpec>? = nil,
    backend: StubBackend = StubBackend(),
    sources: [AnyContractCandidateSource<StubCommand>]
) -> ContractMachine<StubBackend> {
    let resolvedContext: ContractRunContext<StubSpec>
    if let context {
        resolvedContext = context
    } else {
        var resolved = config ?? makeConfig()
        resolved.suppressIssueReporting = true
        resolvedContext = ContractRunContext<StubSpec>(
            config: resolved,
            sequenceGen: stubSequenceGen(),
            commandGen: StubSpec.commandGenerator.gen,
            commandLimit: 5,
            identifySkips: { _ in [] },
            fileID: #fileID,
            filePath: #filePath,
            line: #line,
            column: #column
        )
    }
    return ContractMachine(backend: backend, context: resolvedContext, sources: sources)
}

private func makePipeline(
    propertyPasses: Bool
) -> ContractPipeline<StubBackend> {
    ContractPipeline(
        backend: StubBackend(),
        sequenceGen: stubSequenceGen(),
        commandGen: StubSpec.commandGenerator.gen,
        commandLimit: 5,
        concurrencyLevel: 1,
        identifySkips: { _ in [] },
        property: { _ in propertyPasses },
        invocationCounter: UnsafeSendableBox(0),
        sequenceGenForLength: nil,
        fileID: #fileID,
        filePath: #filePath,
        line: #line,
        column: #column
    )
}

private func label(_ transition: ContractMachine<StubBackend>.Transition) -> String {
    switch transition {
        case .sourceExhausted: "sourceExhausted"
        case .sourceError: "sourceError"
        case .candidateFound: "candidateFound"
        case .pruned: "pruned"
        case .reduced: "reduced"
        case .statsRecorded: "statsRecorded"
        case .assembled: "assembled"
    }
}

private extension AnyContractCandidateSource {
    static func once(
        _ computation: @escaping () throws -> ContractCandidate<Command>?
    ) -> AnyContractCandidateSource {
        var exhausted = false
        return AnyContractCandidateSource {
            guard exhausted == false else { return nil }
            exhausted = true
            return try computation()
        }
    }
}
