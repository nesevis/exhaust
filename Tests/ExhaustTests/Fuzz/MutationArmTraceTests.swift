import ExhaustTestSupport
import Foundation
import Testing
@testable import Exhaust
@testable import ExhaustCore

@Suite("Mutation-arm accounting tests")
struct MutationArmTraceTests {
    @Test("Draws, misses, and admissions are counted apart from the outcome table")
    func ledgerCountersAreIndependent() {
        var ledger = MutationArmLedger()
        ledger.recordDraw(arm: .swap)
        ledger.recordMiss(arm: .swap)
        ledger.recordDraw(arm: .low)
        ledger.record(arm: .low, outcome: .pass)
        ledger.recordAdmission(arm: .low)
        #expect(ledger.draws(arm: .swap) == 1)
        #expect(ledger.misses(arm: .swap) == 1)
        #expect(ledger.count(arm: .swap) == 0)
        #expect(ledger.admissions(arm: .swap) == 0)
        #expect(ledger.draws(arm: .low) == 1)
        #expect(ledger.misses(arm: .low) == 0)
        #expect(ledger.count(arm: .low) == 1)
        #expect(ledger.admissions(arm: .low) == 1)
    }

    /// The synthetic source admits only a handful of mutation candidates, because random sampling covers most of its small edge domain before the mutation phase begins. These two tests therefore assert that admissions are recorded at all, not at what rate.
    @Test("A run records a draw for every arm it picks and an admission for every arm it admits")
    func runRecordsDrawsAndAdmissions() {
        let counts = runCounts(banditBands: true)
        let drawn = MutationArm.allCases.reduce(0) { $0 + counts.mutationArms.draws(arm: $1) }
        let admitted = MutationArm.allCases.reduce(0) { $0 + counts.mutationArms.admissions(arm: $1) }
        let credited = MutationArm.allCases.reduce(0) { $0 + counts.mutationArms.count(arm: $1) }
        #expect(drawn > 0)
        #expect(admitted > 0)
        #expect(admitted <= credited)
    }

    @Test("Admissions are recorded with the bandit off, so both arms of a comparison report the same reward")
    func admissionsAreRecordedWithoutTheBandit() {
        let counts = runCounts(banditBands: false)
        let admitted = MutationArm.allCases.reduce(0) { $0 + counts.mutationArms.admissions(arm: $1) }
        #expect(admitted > 0)
    }

    @Test("A missed arm is counted as drawn and missed, and the band that absorbs the fallback takes the credit")
    func missCreditsTheBandAndRecordsTheMiss() {
        // The graph arms cannot target a single scalar's sequence, so every draw of one misses and falls back to a band.
        let counts = runCounts(banditBands: false, graphMutation: true)
        let graphArms: [MutationArm] = [.swap, .shuffle, .move, .lockstepDelta]
        let graphDraws = graphArms.reduce(0) { $0 + counts.mutationArms.draws(arm: $1) }
        let graphMisses = graphArms.reduce(0) { $0 + counts.mutationArms.misses(arm: $1) }
        let graphCredited = graphArms.reduce(0) { $0 + counts.mutationArms.count(arm: $1) }
        #expect(graphDraws > 0)
        #expect(graphMisses > 0)
        // An arm is credited only when its operator changed the sequence, so a miss can never be credited.
        #expect(graphCredited <= graphDraws - graphMisses)
    }

    @Test("The trace writes one row per arm per completed window")
    func traceWritesOneRowPerArmPerWindow() throws {
        let directory = NSTemporaryDirectory() + "arm-trace-test-\(UUID().uuidString)"
        defer {
            try? FileManager.default.removeItem(atPath: directory)
        }
        var trace = try #require(MutationArmTrace(directory: directory, windowSize: 10, seed: 7))
        var ledger = MutationArmLedger()
        ledger.recordDraw(arm: .low)
        let bandit = MutationBandit()
        for attemptIndex in 1 ... 25 {
            trace.note(attemptIndex: attemptIndex, ledger: ledger, bandit: bandit)
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: directory)
        let contents = try String(contentsOfFile: directory + "/" + #require(files.first), encoding: .utf8)
        let lines = contents.split(separator: "\n")
        #expect(lines.first?.hasPrefix("seed,window,attempts,arm") == true)
        // Two windows closed inside 25 attempts, one row per arm each.
        #expect(lines.count == 1 + 2 * MutationArm.allCases.count)
        #expect(lines.contains { $0.hasPrefix("7,0,10,low,1,0,0,0,") })
    }

    @Test("The new knobs parse from the experiment environment variable")
    func knobsParse() throws {
        let experiments = try FuzzExperiments.parse(environmentValue: "armEligibility=on,armAdmissibility=on")
        #expect(experiments.armEligibility)
        #expect(experiments.armAdmissibility)
        #expect(experiments.banditBands)
        #expect(FuzzExperiments.shipped.armEligibility == false)
        #expect(FuzzExperiments.shipped.armAdmissibility == false)
    }

    @Test("The parity halves of a run's credited candidates sum to its totals")
    func parityHalvesSumToTotals() {
        let counts = runCounts(banditBands: true)
        for arm in MutationArm.allCases {
            #expect(counts.mutationArms.creditedEven(arm: arm) <= counts.mutationArms.count(arm: arm))
            #expect(counts.mutationArms.admissionsEven(arm: arm) <= counts.mutationArms.admissions(arm: arm))
        }
        let credited = MutationArm.allCases.reduce(0) { $0 + counts.mutationArms.count(arm: $1) }
        let even = MutationArm.allCases.reduce(0) { $0 + counts.mutationArms.creditedEven(arm: $1) }
        #expect(even > 0)
        #expect(even < credited)
    }

    // MARK: - Helpers

    private func runCounts(banditBands: Bool, graphMutation: Bool = false) -> FuzzRunCounts {
        var experiments = FuzzExperiments()
        experiments.banditBands = banditBands
        experiments.graphMutation = graphMutation
        experiments.pairMutation = false
        let runner = FuzzRunner(
            gen: Gen.zip(
                Gen.choose(in: 0 ... 1000 as ClosedRange<Int>),
                Gen.choose(in: 0 ... 1000 as ClosedRange<Int>),
                Gen.choose(in: 0 ... 1000 as ClosedRange<Int>)
            ),
            property: { _ in .pass },
            // A small edge domain so random sampling plateaus quickly, with a hit count that varies by value so the mutation phase still has hit-count buckets left to discover and the corpus can still admit.
            source: SyntheticCoverageSource<(Int, Int, Int)>(edgeCount: 16, hitEdges: { value in
                [
                    (edge: value.0 % 8, hitCount: UInt8(max(1, min(255, value.1 / 4)))),
                    (edge: 8 + (value.2 % 8), hitCount: 1),
                ]
            }),
            configuration: FuzzRunnerConfiguration(
                budgetNanoseconds: 60_000_000_000,
                seed: 23,
                attemptLimit: 20000,
                experiments: experiments
            )
        )
        return runner.run().counts
    }
}

@Suite("Arm eligibility tests")
struct ArmEligibilityTests {
    @Test("Admission spacings bucket by power of two and read back as quantiles")
    func spacingBucketsReadBackAsQuantiles() {
        var diagnostics = FuzzDiagnostics()
        for spacing in [0, 1, 3, 7, 100, 100, 5000, 5000, 5000, 200_000] {
            diagnostics.recordAdmissionSpacing(spacing)
        }
        #expect(diagnostics.admissionSpacingBuckets[0] == 2)
        #expect(diagnostics.admissionSpacingQuantile(0.5) > 0)
        #expect(diagnostics.admissionSpacingQuantile(0.95) >= diagnostics.admissionSpacingQuantile(0.5))
        #expect(diagnostics.admissionSpacingQuantile(1.0) >= 131_072)
    }

    @Test("A run records a spacing for every admission that came from a parent")
    func runRecordsSpacings() {
        var experiments = FuzzExperiments()
        experiments.graphMutation = true
        let runner = FuzzRunner(
            gen: Gen.zip(
                Gen.choose(in: 0 ... 1000 as ClosedRange<Int>),
                Gen.choose(in: 0 ... 1000 as ClosedRange<Int>),
                Gen.choose(in: 0 ... 1000 as ClosedRange<Int>)
            ),
            property: { _ in .pass },
            source: SyntheticCoverageSource<(Int, Int, Int)>(edgeCount: 16, hitEdges: { value in
                [
                    (edge: value.0 % 8, hitCount: UInt8(max(1, min(255, value.1 / 4)))),
                    (edge: 8 + (value.2 % 8), hitCount: 1),
                ]
            }),
            configuration: FuzzRunnerConfiguration(
                budgetNanoseconds: 60_000_000_000,
                seed: 23,
                attemptLimit: 20000,
                experiments: experiments
            )
        )
        let result = runner.run()
        #expect(result.diagnostics.admissionSpacingBuckets.reduce(0, +) > 0)
    }

    @Test("The repertoire sights operators that exist only inside unselected pick branches")
    func repertoireReadsUnselectedBranches() throws {
        // Branch 0 is a bare scalar, branch 1 a three-wide zip, so every sibling-span group lives in the alternative a draw of branch 0 never takes.
        let generator = Gen.pick(choices: [
            (1, Gen.choose(in: 0 ... 0 as ClosedRange<Int>)),
            (1, Gen.zip(
                Gen.choose(in: 100 ... 200 as ClosedRange<Int>),
                Gen.choose(in: 100 ... 200 as ClosedRange<Int>),
                Gen.choose(in: 100 ... 200 as ClosedRange<Int>)
            ).map { $0.0 + $0.1 + $0.2 }),
        ])
        let tree = try #require(branchZeroTree(of: generator))
        let graph = ChoiceGraphBuilder.build(from: tree)
        let sighted = MutationArmRepertoire.sighted(in: graph)
        #expect(sighted.contains(.swap))
        #expect(sighted.contains(.shuffle))
        #expect(sighted.contains(.move))
        #expect(sighted.contains(.lockstepDelta))
        #expect(sighted.contains(.typedCrossover))

        // The same tree read through the targeting tables reports nothing: their queries address sequence positions, which an unselected branch has none of.
        let targets = MutationTargets(tree: tree)
        #expect(targets.hasSwappableGroup(minimumSize: 2) == false)
        #expect(targets.hasTandemGroup == false)
    }

    @Test("The bandit draws only from the eligible set and renormalises over it")
    func banditRespectsTheEligibleSet() throws {
        let bandit = MutationBandit(arms: [.low, .medium, .high, .splice])
        var eligible = MutationArmSet(.low)
        eligible.insert(.high)
        var seen: Set<MutationArm> = []
        for step in 0 ..< 200 {
            let arm = try #require(bandit.pick(random: Double(step) / 200, eligible: eligible))
            seen.insert(arm)
        }
        #expect(seen == [.low, .high])
    }

    @Test("An empty eligible set yields nil rather than an arm the caller cannot use")
    func banditReportsAnEmptySet() {
        let bandit = MutationBandit(arms: [.low, .medium])
        #expect(bandit.pick(random: 0.5, eligible: MutationArmSet(.twinSplice)) == nil)
    }

    @Test("A gated run never draws an arm whose operator cannot fire, and still finds faults")
    func gatedRunAvoidsInapplicableArms() {
        var experiments = FuzzExperiments()
        experiments.armEligibility = true
        experiments.graphMutation = true
        experiments.pairMutation = true
        let runner = FuzzRunner(
            gen: Gen.zip(
                Gen.choose(in: 0 ... 1000 as ClosedRange<Int>),
                Gen.choose(in: 0 ... 1000 as ClosedRange<Int>),
                Gen.choose(in: 0 ... 1000 as ClosedRange<Int>)
            ),
            property: { value in
                value.0 + value.1 + value.2 > 2800 ? .fail(.returnedFalse) : .pass
            },
            source: SyntheticCoverageSource<(Int, Int, Int)>(edgeCount: 32, edges: { value in
                [value.0 & 0b111, 8 + (value.1 & 0b111), 16 + (value.2 & 0b111)]
            }),
            configuration: FuzzRunnerConfiguration(
                budgetNanoseconds: 60_000_000_000,
                seed: 23,
                attemptLimit: 5000,
                experiments: experiments
            )
        )
        let result = runner.run()
        let counts = result.counts
        // A zip of scalars has no bind region, so splice cannot fire and must never be drawn. The
        // sibling-span operators are a different matter: three same-shaped children do form a group,
        // so they are applicable and their misses come from the position-fit check instead.
        #expect(counts.mutationArms.draws(arm: .splice) == 0)
        #expect(result.clusters.isEmpty == false)
    }

    @Test("The gate keeps the bands on a generator with no branch point, where the medium band is the only arm that duplicates a block")
    func gatedRunKeepsTheBands() {
        var experiments = FuzzExperiments()
        experiments.armEligibility = true
        experiments.graphMutation = true
        experiments.pairMutation = true
        // A zip of scalars has no pick site anywhere, so no parent's sequence ever carries a branch marker.
        let runner = FuzzRunner(
            gen: Gen.zip(
                Gen.choose(in: 0 ... 1000 as ClosedRange<Int>),
                Gen.choose(in: 0 ... 1000 as ClosedRange<Int>),
                Gen.choose(in: 0 ... 1000 as ClosedRange<Int>)
            ),
            property: { value in
                value.0 + value.1 + value.2 > 2900 ? .fail(.returnedFalse) : .pass
            },
            source: SyntheticCoverageSource<(Int, Int, Int)>(edgeCount: 64, hitEdges: { value in
                [
                    (edge: value.0 % 16, hitCount: UInt8(max(1, min(255, value.1 / 4)))),
                    (edge: 16 + (value.1 % 16), hitCount: 1),
                ]
            }),
            configuration: FuzzRunnerConfiguration(
                budgetNanoseconds: 60_000_000_000,
                seed: 23,
                attemptLimit: 20000,
                experiments: experiments
            )
        )
        let counts = runner.run().counts
        for band in [MutationArm.low, .medium, .high] {
            #expect(counts.mutationArms.draws(arm: band) > 0)
        }
        // The medium band falls back internally rather than declining, so the absence of a branch marker costs it nothing: what misses are the handful of draws whose block edit happened to reproduce the parent.
        let draws = counts.mutationArms.draws(arm: .medium)
        #expect(counts.mutationArms.misses(arm: .medium) * 5 < draws)
    }

    @Test("A structural sample that misses a nested alternative does not exclude the operator, because parents that can target it say otherwise")
    func parentEvidenceWidensTheRepertoire() throws {
        var experiments = FuzzExperiments()
        experiments.armAdmissibility = true
        experiments.graphMutation = true
        experiments.pairMutation = true
        // The swappable group sits inside a pick nested one level below the outer pick's alternatives. Expanding the outer alternatives does not descend into their own picks, so a parent that took the scalar branch produces a sample with no group in it at all.
        let generator = Gen.pick(choices: [
            (1, Gen.choose(in: 0 ... 3 as ClosedRange<Int>)),
            (1, Gen.pick(choices: [
                (1, Gen.choose(in: 4 ... 7 as ClosedRange<Int>)),
                (1, Gen.zip(
                    Gen.choose(in: 0 ... 200 as ClosedRange<Int>),
                    Gen.choose(in: 0 ... 200 as ClosedRange<Int>),
                    Gen.choose(in: 0 ... 200 as ClosedRange<Int>)
                ).map { $0.0 + $0.1 + $0.2 }),
            ])),
        ])
        let runner = FuzzRunner(
            gen: generator,
            property: { _ in .pass },
            source: SyntheticCoverageSource<Int>(edgeCount: 64, hitEdges: { value in
                [(edge: value % 32, hitCount: UInt8(max(1, min(255, value / 2))))]
            }),
            configuration: FuzzRunnerConfiguration(
                budgetNanoseconds: 60_000_000_000,
                seed: 23,
                attemptLimit: 20000,
                experiments: experiments
            )
        )
        _ = runner.run()
        let parentIndex = try #require(runner.corpus.parentIndices.first { index in
            runner.corpus.mutationTargets(forParentAt: index)?.hasSwappableGroup(minimumSize: 2) == true
        })
        let parent = runner.corpus.entries[parentIndex]

        // A structural sample that never descended into the nested alternative, so it sighted no sibling-span operator at all. Widening happens at admission, once admissions have spaced out past the slowdown.
        runner.sightedArms = MutationArmSet.bands
        runner.attemptsAtPreviousAdmission = 0
        #expect(runner.counts.totalAttempts >= FuzzTunables.armAdmissibilitySlowdown)
        runner.noteStructuralAdmissibility(of: parent.sequence, parentIndex: parentIndex)
        let widened = try #require(runner.sightedArms)
        #expect(widened.contains(.swap))
    }

    @Test("A trace gap wider than a window closes one window, not one per elapsed boundary")
    func traceSkipsElapsedBoundaries() throws {
        let directory = NSTemporaryDirectory() + "arm-trace-test-\(UUID().uuidString)"
        defer {
            try? FileManager.default.removeItem(atPath: directory)
        }
        var trace = try #require(MutationArmTrace(directory: directory, windowSize: 10, seed: 7))
        let ledger = MutationArmLedger()
        let bandit = MutationBandit()
        // Duplicates and materializer rejections advance the timeline without a row, so the next attempt to arrive can be many windows past the boundary.
        trace.note(attemptIndex: 1, ledger: ledger, bandit: bandit)
        for attemptIndex in 100_000 ... 100_009 {
            trace.note(attemptIndex: attemptIndex, ledger: ledger, bandit: bandit)
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: directory)
        let contents = try String(contentsOfFile: directory + "/" + #require(files.first), encoding: .utf8)
        let lines = contents.split(separator: "\n")
        #expect(lines.count == 1 + MutationArm.allCases.count)
    }

    @Test("The fixed scheduler honours the gate too, so a bandit-off comparison measures the same restriction")
    func gatedRunAvoidsInapplicableArmsWithoutTheBandit() {
        var experiments = FuzzExperiments()
        experiments.armEligibility = true
        experiments.banditBands = false
        experiments.graphMutation = true
        experiments.pairMutation = true
        let runner = FuzzRunner(
            gen: Gen.zip(
                Gen.choose(in: 0 ... 1000 as ClosedRange<Int>),
                Gen.choose(in: 0 ... 1000 as ClosedRange<Int>),
                Gen.choose(in: 0 ... 1000 as ClosedRange<Int>)
            ),
            property: { value in
                value.0 + value.1 + value.2 > 2800 ? .fail(.returnedFalse) : .pass
            },
            source: SyntheticCoverageSource<(Int, Int, Int)>(edgeCount: 32, edges: { value in
                [value.0 & 0b111, 8 + (value.1 & 0b111), 16 + (value.2 & 0b111)]
            }),
            configuration: FuzzRunnerConfiguration(
                budgetNanoseconds: 60_000_000_000,
                seed: 23,
                attemptLimit: 5000,
                experiments: experiments
            )
        )
        let counts = runner.run().counts
        #expect(counts.mutationArms.draws(arm: .splice) == 0)
        let drawn = MutationArm.allCases.reduce(0) { $0 + counts.mutationArms.draws(arm: $1) }
        #expect(drawn > 0)
    }

    @Test("The reward divides by the probability the restricted draw ran at, not the unconditional one")
    func rewardUsesTheConditionalProbability() {
        let bandit = MutationBandit(arms: [.low, .medium, .high, .splice])
        let eligible = MutationArmSet(.low, .high)
        let conditional = bandit.probability(of: .low, eligible: eligible)
        // Two of four arms survive an even distribution, so each takes half the mass.
        #expect(abs(conditional - 0.5) < 1e-9)
        #expect(abs(conditional + bandit.probability(of: .high, eligible: eligible) - 1) < 1e-9)
        // An arm the gate withheld was not drawn at all.
        #expect(bandit.probability(of: .splice, eligible: eligible) == 0)

        // The inflation the unconditional probability would cause: with half the mass withheld, every exponent doubles.
        var conditionalBandit = MutationBandit(arms: [.low, .medium, .high, .splice])
        var unconditionalBandit = conditionalBandit
        conditionalBandit.reward(.low, drawProbability: conditional)
        unconditionalBandit.reward(.low, drawProbability: unconditionalBandit.probability(of: .low))
        #expect(unconditionalBandit.probability(of: .low) > conditionalBandit.probability(of: .low))
    }

    @Test("A resumed run anchors its first window on the timeline it resumed at")
    func traceAnchorsOnTheResumedTimeline() throws {
        let directory = NSTemporaryDirectory() + "arm-trace-test-\(UUID().uuidString)"
        defer {
            try? FileManager.default.removeItem(atPath: directory)
        }
        var trace = try #require(MutationArmTrace(directory: directory, windowSize: 10, seed: 7))
        let ledger = MutationArmLedger()
        let bandit = MutationBandit()
        // A predecessor consumed 100,000 attempts, so this process's first attempt is numbered far past any boundary counted from zero.
        for attemptIndex in 100_000 ... 100_025 {
            trace.note(attemptIndex: attemptIndex, ledger: ledger, bandit: bandit)
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: directory)
        let contents = try String(contentsOfFile: directory + "/" + #require(files.first), encoding: .utf8)
        let lines = contents.split(separator: "\n")
        // Two windows closed inside 25 attempts, the same as a run that started at zero.
        #expect(lines.count == 1 + 2 * MutationArm.allCases.count)
        #expect(lines.contains { $0.hasPrefix("7,0,100010,low,") })
    }

    @Test("A generator with no bind anywhere reports no bind region on the flat sequence")
    func flatSequenceReportsTheAbsenceOfBinds() throws {
        // A zip of scalars: no bind anywhere in the generator, so splice can never fire in any run of it.
        let gen = Gen.zip(
            Gen.choose(in: 0 ... 1000 as ClosedRange<Int>),
            Gen.choose(in: 0 ... 1000 as ClosedRange<Int>),
            Gen.choose(in: 0 ... 1000 as ClosedRange<Int>)
        )
        var interpreter = ValueAndChoiceTreeInterpreter(gen, seed: 7, maxRuns: 1)
        let drawn = try #require(try interpreter.next())
        let sequence = ChoiceSequence.flatten(drawn.tree)
        let layout = FuzzMutator.structuralLayout(of: sequence)
        #expect(layout.hasBindRegion == false)
        #expect(layout.valueIndices.isEmpty == false)
    }

    @Test("Structural admissibility never widens the draw and still finds faults")
    func admissibilityIsSafe() {
        func run(admissibility: Bool) -> (counts: FuzzRunCounts, faults: Int) {
            var experiments = FuzzExperiments()
            experiments.armAdmissibility = admissibility
            let runner = FuzzRunner(
                gen: Gen.zip(
                    Gen.choose(in: 0 ... 1000 as ClosedRange<Int>),
                    Gen.choose(in: 0 ... 1000 as ClosedRange<Int>),
                    Gen.choose(in: 0 ... 1000 as ClosedRange<Int>)
                ),
                property: { value in
                    value.0 + value.1 + value.2 > 2800 ? .fail(.returnedFalse) : .pass
                },
                source: SyntheticCoverageSource<(Int, Int, Int)>(edgeCount: 32, edges: { value in
                    [value.0 & 0b111, 8 + (value.1 & 0b111), 16 + (value.2 & 0b111)]
                }),
                configuration: FuzzRunnerConfiguration(
                    budgetNanoseconds: 60_000_000_000,
                    seed: 23,
                    attemptLimit: 20000,
                    experiments: experiments
                )
            )
            let result = runner.run()
            return (result.counts, result.clusters.count)
        }
        let gated = run(admissibility: true)
        let open = run(admissibility: false)
        #expect(gated.counts.mutationArms.draws(arm: .splice) <= open.counts.mutationArms.draws(arm: .splice))
        #expect(gated.faults > 0)
    }

    @Test("Without the gate the same run does draw the arm that cannot fire")
    func ungatedRunDrawsInapplicableArms() {
        var experiments = FuzzExperiments()
        experiments.armEligibility = false
        let runner = FuzzRunner(
            gen: Gen.zip(
                Gen.choose(in: 0 ... 1000 as ClosedRange<Int>),
                Gen.choose(in: 0 ... 1000 as ClosedRange<Int>),
                Gen.choose(in: 0 ... 1000 as ClosedRange<Int>)
            ),
            property: { value in
                value.0 + value.1 + value.2 > 2800 ? .fail(.returnedFalse) : .pass
            },
            source: SyntheticCoverageSource<(Int, Int, Int)>(edgeCount: 32, edges: { value in
                [value.0 & 0b111, 8 + (value.1 & 0b111), 16 + (value.2 & 0b111)]
            }),
            configuration: FuzzRunnerConfiguration(
                budgetNanoseconds: 60_000_000_000,
                seed: 23,
                attemptLimit: 5000,
                experiments: experiments
            )
        )
        #expect(runner.run().counts.mutationArms.draws(arm: .splice) > 0)
    }
}

// MARK: - Helpers

/// The first tree in a short seed sweep whose pick took branch zero, materialized with its alternatives intact.
private func branchZeroTree(of generator: Generator<Int>) -> ChoiceTree? {
    for seed in UInt64(0) ..< 40 {
        var interpreter = ValueAndChoiceTreeInterpreter(
            generator,
            materializePicks: true,
            seed: seed,
            maxRuns: 1
        )
        guard let (value, tree) = try? interpreter.next(), value == 0 else {
            continue
        }
        return tree
    }
    return nil
}
