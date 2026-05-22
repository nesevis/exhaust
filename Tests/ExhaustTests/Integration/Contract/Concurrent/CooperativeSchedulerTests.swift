import Testing
@testable import Exhaust
import ExhaustTestSupport

@Suite("Cooperative scheduler behavior", .tags(.contract))
struct CooperativeSchedulerTests {
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("Sequential prefix passes without triggering concurrency bugs")
    func sequentialPrefixPasses() {
        let commands: [(ScheduleMarker, NonAtomicCounterSpec.Command)] = [
            (.prefix, .increment),
            (.prefix, .increment),
            (.prefix, .decrement),
        ]
        let result = drainSchedule(
            taggedCommands: commands,
            specInit: { NonAtomicCounterSpec() },
            concurrencyLevel: 2,
            recordTrace: true
        )
        #expect(result.passed, "Sequential execution should not trigger a concurrency bug")
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("Same seed produces identical trace across repeated runs")
    func strictDeterminism() async throws {
        var traces: [[TraceStep]] = []
        for _ in 0 ..< 10 {
            let result = try #require(
                await __runContractConcurrent(
                    NonAtomicCounterSpec.self,
                    settings: [.commandLimit(6), .budget(.custom(coverage: 0, sampling: 200)), .replay(.numeric(12345)), .suppress(.issueReporting)]
                )
            )
            traces.append(result.trace)
        }
        for trace in traces.dropFirst() {
            #expect(trace.count == traces[0].count, "All runs with the same seed must produce identical traces")
            for (step, expected) in zip(trace, traces[0]) {
                #expect(step.command == expected.command)
            }
        }
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("Reduction produces a counterexample that still fails on replay")
    func reducedCounterexampleReproduces() async throws {
        let result = try #require(
            await __runContractConcurrent(
                NonAtomicCounterSpec.self,
                settings: [.commandLimit(8), .budget(.custom(coverage: 0, sampling: 200)), .suppress(.issueReporting)]
            )
        )
        let replayResult = try #require(
            await __runContractConcurrent(
                NonAtomicCounterSpec.self,
                settings: [.commandLimit(8), .budget(.custom(coverage: 0, sampling: 200)), .replay(.numeric(result.seed!)), .suppress(.issueReporting)]
            )
        )
        #expect(replayResult.commands.count == result.commands.count, "Replaying the seed should reproduce the same counterexample size")
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("concurrencyLevel 1 runs everything sequentially and finds no concurrency bugs")
    func concurrencyLevelOneIsSequential() async {
        let result = await __runContractConcurrent(
            NonAtomicCounterSpec.self,
            settings: [.concurrency(1), .commandLimit(8), .budget(.custom(coverage: 0, sampling: 200)), .suppress(.issueReporting)]
        )
        #expect(result == nil, "With concurrency level 1, all commands run as prefix — no interleaving, no bug found")
    }
}
