import Testing
@testable import ExhaustCore

@Suite("Scoped source scheduling")
struct ScopedSourceSchedulingTests {
    @Test("The initial batch runs before a higher-priority source, then ordinary ordering resumes")
    func initialBatchRunsFirst() throws {
        let graph = ChoiceGraph.build(from: .group([.uint64Sequence([1, 2]), .uint64Sequence([3, 4])]))
        let scope = try #require(RemovalQuery.elementRemovalScopes(graph: graph).first)
        let highPriority = ScopedSortedSource([pricedRemoval(scope, benefit: 1000)], invalidation: .structuralChange)
        let batch = ScopedBatchedCrossSequenceRemovalSource(graph: graph)
        var sources: [any ScopedSource] = [highPriority, batch]

        #expect(ScopedSources.highestPrioritySourceIndex(&sources) == 1)
        #expect(ScopedSources.highestPrioritySourceIndex(&sources) == 1)
        let initial = try #require(sources[1].nextScope())
        guard case let .removal(.elements(initialScope)) = initial.encoderScope else {
            Issue.record("Expected the initial batched removal")
            return
        }
        #expect(initialScope.targets.count == 2)
        #expect(sources[1].prefersInitialDispatch == false)

        #expect(ScopedSources.highestPrioritySourceIndex(&sources) == 0)
        _ = try #require(sources[0].nextScope())
        #expect(ScopedSources.highestPrioritySourceIndex(&sources) == 0)
        #expect(sources.count == 1)
        #expect(sources[0] === batch)
        let next = try #require(sources[0].nextScope())
        guard case let .removal(.elements(nextScope)) = next.encoderScope else {
            Issue.record("Expected a bisected removal")
            return
        }
        #expect(nextScope.targets.count == 1)
    }

    @Test("Discarding exhausted sources preserves priority ties and each surviving cursor")
    func exhaustedSourcesPreserveTies() throws {
        let graph = ChoiceGraph.build(from: .uint64Sequence([1, 2]))
        let scope = try #require(RemovalQuery.elementRemovalScopes(graph: graph).first)
        let first = ScopedSortedSource([pricedRemoval(scope, benefit: 1)], invalidation: .anyValueChange)
        let second = ScopedSortedSource([pricedRemoval(scope, benefit: 1)], invalidation: .leafKindChange)
        let empty = ScopedSortedSource([], invalidation: .structuralChange)
        var sources: [any ScopedSource] = [empty, first, empty, second]

        #expect(ScopedSources.highestPrioritySourceIndex(&sources) == 0)
        #expect(sources.count == 2)
        #expect(sources[0] === first)
        #expect(sources[1] === second)
        #expect(sources[0].prefersInitialDispatch == false)
        _ = try #require(sources[0].nextScope())
        #expect(sources[0].invalidation == .anyValueChange)

        #expect(ScopedSources.highestPrioritySourceIndex(&sources) == 0)
        #expect(sources.count == 1)
        #expect(sources[0] === second)
        #expect(sources[0].invalidation == .leafKindChange)
        _ = try #require(sources[0].nextScope())
        #expect(ScopedSources.highestPrioritySourceIndex(&sources) == nil)
        #expect(sources.isEmpty)
    }

    @Test("Demotion drops the migration source without draining its remaining scopes")
    func demotionDropsMigrationSource() throws {
        let array = Gen.arrayOf(Gen.choose(in: UInt64(0) ... 10), within: 0 ... 4)
        let generator = Gen.zip(array, array, array)
        let start: ([UInt64], [UInt64], [UInt64]) = ([1, 2], [3, 4], [5, 6])
        let tree = try #require(try Interpreters.reflect(generator, with: start))
        var tuning = ScopedReductionTuning()
        tuning.migrationDemotionThreshold = 1
        var runner = ScopedReductionRunner(
            generator: generator,
            initialTree: tree,
            initialOutput: start,
            configuration: .init(maxStalls: 1, enabledEncoders: [.migration], tuning: tuning),
            collectStats: false,
            property: { _ in false }
        )
        let migration = ScopedMigrationSource(graph: runner.graph)
        _ = try #require(migration.dispatchPriority)
        runner.sources = [migration]
        runner.consecutiveRejectsByEncoder[.migration] = 1

        _ = runner.dispatchCycle()

        #expect(runner.sources.isEmpty)
        #expect(migration.dispatchPriority != nil)
    }
}

// MARK: - Helpers

private func pricedRemoval(_ scope: ElementRemovalScope, benefit: Int) -> PricedEncoderScope {
    PricedEncoderScope(
        encoderScope: .removal(.elements(scope)),
        priority: DispatchPriority(structuralBenefit: benefit, valueBenefit: 0, reductionMagnitude: 0, estimatedCost: 1)
    )
}
