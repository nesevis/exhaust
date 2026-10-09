import Testing
@testable import ExhaustCore

@Suite("Reduction entry points")
struct ReductionEntryPointTests {
    @Test("Stats and non-stats entry points preserve the same probe stream", arguments: [false, true])
    func identicalProbeStream(structural: Bool) throws {
        let generator = Gen.arrayOf(Gen.choose(in: 0 ... 100), within: 0 ... 8)
        let initial = [10, 20, 30, 40]
        let tree = try #require(try Interpreters.reflect(generator, with: initial))
        let configuration = Interpreters.ReducerConfiguration(
            maxStalls: 2,
            enabledEncoders: structural ? nil : [.valueSearch]
        )
        var uncountedProbes: [[Int]] = []
        let uncounted = Interpreters.choiceGraphReduce(
            gen: generator,
            tree: tree,
            output: initial,
            config: configuration,
            property: { values in
                uncountedProbes.append(values)
                return values.reduce(0, +) < 50
            }
        )
        var countedProbes: [[Int]] = []
        let counted = Interpreters.choiceGraphReduceCollectingStats(
            gen: generator,
            tree: tree,
            output: initial,
            config: configuration,
            property: { values in
                countedProbes.append(values)
                return values.reduce(0, +) < 50
            }
        )
        let uncountedResult = try #require(uncounted.counterexample)
        let countedResult = try #require(counted.outcome.counterexample)
        #expect(uncountedResult.0 == countedResult.0)
        #expect(uncountedResult.1 == countedResult.1)
        #expect(uncountedProbes.isEmpty == false)
        #expect(uncountedProbes == countedProbes)
        #expect(counted.stats.reductionProbesWherePropertyPassed + counted.stats.reductionProbesWherePropertyFailed == countedProbes.count)
    }

    @Test("The non-stats driver performs no probe accounting or step timing")
    func uncountedDriver() throws {
        let generator = Gen.choose(in: 0 ... 100)
        let tree = try #require(try Interpreters.reflect(generator, with: 42))
        let result = ChoiceGraphScheduler.run(
            gen: generator,
            initialTree: tree,
            initialOutput: 42,
            config: .init(maxStalls: 2),
            collectStats: false,
            property: { $0 < 7 }
        )
        #expect(result.outcome.counterexample?.1 == 7)
        #expect(result.stats.encoderCounts.isEmpty)
        #expect(result.stats.totalMaterializations == 0)
        #expect(result.stats.stepTimings.dispatchCount == 0)
        #expect(result.stats.stepTimings.passApplyCount == 0)
        #expect(result.stats.stepTimings.encodeCount == 0)
        #expect(result.stats.stepTimings.decodeCount == 0)
    }
}
