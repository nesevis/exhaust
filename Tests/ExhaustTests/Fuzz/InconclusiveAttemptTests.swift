import ExhaustCore
import ExhaustTestSupport
import Testing
@testable import Exhaust

/// What the search does with an evaluation that reached no verdict.
///
/// A `.tasks` probe whose drain stalls has not judged its input: the coverage it recorded describes a stalled execution rather than the commands. Counting it as a pass puts the shape of a timeout into the corpus as a mutation parent and resets the plateau window on it, so the search then spends its budget mutating a hang.
@Suite("Inconclusive attempts")
struct InconclusiveAttemptTests {
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("A stalled drain is inconclusive rather than a pass, and counts as a stalled search")
    func stalledDrainIsInconclusive() throws {
        let telemetry = __ExhaustRuntime.TasksRunTelemetry()
        let adapter = try #require(__ExhaustRuntime.buildTasksSpecAdapter(
            StallingSpec.self,
            concurrencyLevel: 2,
            idleTimeoutMilliseconds: 50,
            telemetry: telemetry
        ))
        let tagged: [(ScheduleMarker, StallingSpec.Command)] = [(ScheduleMarker(rawValue: 1), .parkForever)]
        let verdict = adapter.property(SpecCandidateValue(setupStep: nil, taggedCommands: tagged))

        #expect(verdict.isInconclusive)
        #expect(verdict.isFailure == false, "a stall is not a counterexample")
        #expect(telemetry.stalledSearches == 1)
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("Work that ignores cancellation reports as escaped, not merely inconclusive")
    func escapedWorkReportsAsEscaped() throws {
        let telemetry = __ExhaustRuntime.TasksRunTelemetry()
        let adapter = try #require(__ExhaustRuntime.buildTasksSpecAdapter(
            StallingSpec.self,
            concurrencyLevel: 2,
            idleTimeoutMilliseconds: 50,
            telemetry: telemetry
        ))
        // `parkForever` suspends on a continuation nothing resumes, so cancellation has no suspension point to land on and the command is still running when the probe returns.
        let tagged: [(ScheduleMarker, StallingSpec.Command)] = [(ScheduleMarker(rawValue: 1), .parkForever)]
        let verdict = adapter.property(SpecCandidateValue(setupStep: nil, taggedCommands: tagged))

        #expect(verdict.isEscaped)
        #expect(verdict.isInconclusive, "an escape is still no verdict on the input")
        #expect(telemetry.stalledSearches == 1)
    }

    @Test("An escaped verdict ends the run and keeps the attempt out of the corpus")
    func escapedVerdictEndsTheRun() {
        // Everything after an escape would be measured against work that is still running, so one escaped attempt is the last attempt the run makes.
        let runner = FuzzRunner(
            gen: Gen.choose(in: 0 ... 100 as ClosedRange<Int>),
            property: { _ in .escaped },
            source: SyntheticCoverageSource<Int>(
                edgeCount: 16,
                reportsLiveCoverage: true,
                edges: { _ in [] }
            ),
            configuration: FuzzRunnerConfiguration(
                budgetNanoseconds: 60_000_000_000,
                seed: 3,
                skipScreening: true,
                attemptLimit: 40
            )
        )
        let result = runner.run()

        #expect(result.termination == .uncontainedAsyncWork)
        #expect(result.counts.evaluatedSearchCases == 1)
        #expect(result.counts.inconclusiveAttempts == 1)
        #expect(result.corpusEntryCount == 0)
        #expect(result.incidenceSampleCount == 0)
    }

    @Test("An inconclusive verdict is counted and never offered to the corpus")
    func inconclusiveAttemptsStayOutOfTheCorpus() {
        // Every attempt reaches no verdict, so a corpus that admitted any of them would be admitting the shape of a timeout.
        let runner = FuzzRunner(
            gen: Gen.choose(in: 0 ... 100 as ClosedRange<Int>),
            property: { _ in .inconclusive },
            source: SyntheticCoverageSource<Int>(edgeCount: 16, edges: { [abs($0) % 16] }),
            configuration: FuzzRunnerConfiguration(
                budgetNanoseconds: 60_000_000_000,
                seed: 3,
                skipScreening: true,
                attemptLimit: 40
            )
        )
        let result = runner.run()

        #expect(result.counts.evaluatedSearchCases > 0, "nothing ran, so the assertions below would hold vacuously")
        #expect(result.counts.inconclusiveAttempts == result.counts.evaluatedSearchCases)
        #expect(result.corpusEntryCount == 0)
        #expect(result.clusters.isEmpty)
        #expect(result.incidenceSampleCount == 0)
        #expect(runner.attemptsSinceAdmission == result.counts.inconclusiveAttempts)
    }

    @Test("A passing run with the same generator does fill the corpus")
    func passingAttemptsDoEnterTheCorpus() {
        // The control for the test above: the corpus being empty there has to be the verdict's doing, not the source's.
        let runner = FuzzRunner(
            gen: Gen.choose(in: 0 ... 100 as ClosedRange<Int>),
            property: { _ in .pass },
            source: SyntheticCoverageSource<Int>(edgeCount: 16, edges: { [abs($0) % 16] }),
            configuration: FuzzRunnerConfiguration(
                budgetNanoseconds: 60_000_000_000,
                seed: 3,
                skipScreening: true,
                attemptLimit: 40
            )
        )
        let result = runner.run()

        #expect(result.counts.inconclusiveAttempts == 0)
        #expect(result.corpusEntryCount > 0)
    }
}
