//
//  MigrationDemotionTests.swift
//  Exhaust
//

import Testing
@testable import ExhaustCore

// MARK: - Migration Demotion Tests

/// Pins the migration demotion mechanism: after ``SchedulerTuning/migrationDemotionThreshold`` consecutive fully-rejected migration passes, dispatch skips migration for the rest of the run, and the skip must not change the reduction destination.
@Suite("Migration demotion")
struct MigrationDemotionTests {
    @Test("Demotion stops migration dispatches at the threshold without changing the destination")
    func demotionStopsFruitlessMigration() throws {
        let (baselineMachine, baselineLog) = try runReduction(migrationDemotionThreshold: 0)
        let (demotedMachine, demotedLog) = try runReduction(migrationDemotionThreshold: 2)

        let baselineMigrationPasses = baselineLog.filter { $0.encoderName == .migration }
        let demotedMigrationPasses = demotedLog.filter { $0.encoderName == .migration }

        // The workload's migrations are all fruitless: moving an element out of the first array un-fails the property.
        #expect(baselineMigrationPasses.allSatisfy { $0.acceptCount == 0 })

        // The baseline must dispatch migration often enough that the threshold binds, or the comparison is vacuous.
        #expect(baselineMigrationPasses.count > 2)
        #expect(demotedMigrationPasses.count == 2)

        // Cost-only: skipping the fruitless passes must not change where reduction lands.
        #expect(demotedMachine.sequence == baselineMachine.sequence)
    }

    @Test("Zero threshold never demotes")
    func zeroThresholdNeverDemotes() throws {
        let (_, log) = try runReduction(migrationDemotionThreshold: 0)
        let migrationPasses = log.filter { $0.encoderName == .migration }
        #expect(migrationPasses.count > 2)
    }

    @Test("A migration acceptance resets the consecutive-reject counter")
    func acceptanceResetsCounter() throws {
        var machine = try makeMachine(migrationDemotionThreshold: 3)
        guard let transformation = anyTransformation(graph: machine.graph) else {
            Issue.record("No minimization scope on the test graph")
            return
        }

        _ = machine.applyPassReport(migrationReport(transformation: transformation, accepted: false))
        _ = machine.applyPassReport(migrationReport(transformation: transformation, accepted: false))
        #expect(machine.migrationConsecutiveRejects == 2)

        _ = machine.applyPassReport(migrationReport(transformation: transformation, accepted: true))
        #expect(machine.migrationConsecutiveRejects == 0)

        _ = machine.applyPassReport(migrationReport(transformation: transformation, accepted: false))
        #expect(machine.migrationConsecutiveRejects == 1)
    }

    @Test("Non-migration passes do not touch the consecutive-reject counter")
    func otherEncodersDoNotTouchCounter() throws {
        var machine = try makeMachine(migrationDemotionThreshold: 3)
        guard let transformation = anyTransformation(graph: machine.graph) else {
            Issue.record("No minimization scope on the test graph")
            return
        }

        _ = machine.applyPassReport(migrationReport(transformation: transformation, accepted: false))
        _ = machine.applyPassReport(passReport(encoderName: .valueSearch, transformation: transformation, accepted: true))
        _ = machine.applyPassReport(passReport(encoderName: .deletion, transformation: transformation, accepted: false))
        #expect(machine.migrationConsecutiveRejects == 1)
    }
}

// MARK: - Helpers

/// Two independent sibling sequences of the same element type: the topology migration candidates require. The property fails only while the first array holds at least three elements, so every migration (which can only move elements from the first array to the second) un-fails the property and is rejected.
private let migrationGen = Gen.zip(
    Gen.arrayOf(Gen.choose(in: UInt64(0) ... 100), within: 0 ... 12),
    Gen.arrayOf(Gen.choose(in: UInt64(0) ... 100), within: 0 ... 12)
)

private let migrationProperty: @Sendable (([UInt64], [UInt64])) -> Bool = { pair in
    pair.0.count < 3
}

private func makeMachine(migrationDemotionThreshold: Int) throws -> ReductionMachine {
    var iterator = ValueAndChoiceTreeInterpreter(migrationGen, materializePicks: false, seed: 11, maxRuns: 2000)
    var found: (([UInt64], [UInt64]), ChoiceTree)?
    while let pair = try iterator.next() {
        if migrationProperty(pair.0) == false {
            found = pair
            break
        }
    }
    let (value, tree) = try #require(found)

    var tuning = SchedulerTuning()
    tuning.migrationDemotionThreshold = migrationDemotionThreshold
    var machine = ReductionMachine(
        gen: migrationGen,
        initialTree: tree,
        initialOutput: value,
        config: Interpreters.ReducerConfiguration(maxStalls: 4, tuning: tuning),
        collectStats: true,
        property: migrationProperty
    )
    machine.collectDiagnostics = true
    return machine
}

private func runReduction(migrationDemotionThreshold: Int) throws -> (machine: ReductionMachine, log: [DispatchRecord]) {
    var machine = try makeMachine(migrationDemotionThreshold: migrationDemotionThreshold)
    while try machine.next() != nil {}
    return (machine, machine.stats.dispatchLog)
}

private func anyTransformation(graph: ChoiceGraph) -> GraphTransformation? {
    guard let firstScope = MinimizationQuery.build(graph: graph).first else { return nil }
    return GraphTransformation(
        operation: .minimize(firstScope),
        priority: DispatchPriority(
            structuralBenefit: 0,
            valueBenefit: 0,
            reductionMagnitude: 0,
            estimatedCost: 10
        )
    )
}

private func migrationReport(transformation: GraphTransformation, accepted: Bool) -> PassReport {
    passReport(encoderName: .migration, transformation: transformation, accepted: accepted)
}

private func passReport(encoderName: EncoderName, transformation: GraphTransformation, accepted: Bool) -> PassReport {
    PassReport(
        encoderName: encoderName,
        transformation: transformation,
        boundValueFingerprint: nil,
        composedUpstreamLifts: nil,
        counts: ReductionProbeCounts(
            emitted: 1,
            accepted: accepted ? 1 : 0,
            propertyPassed: accepted ? 0 : 1,
            propertyFailed: accepted ? 1 : 0,
            materializationAttempts: accepted ? 2 : 1
        ),
        anyAccepted: accepted,
        anyRequiresRebuild: false,
        latestTreeIsStripped: false,
        convergenceRecords: [:],
        hadReplacementShortlexRejection: false,
        acceptedLeafNodeIDs: []
    )
}
