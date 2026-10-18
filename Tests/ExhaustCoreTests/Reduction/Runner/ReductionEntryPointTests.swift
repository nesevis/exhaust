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

    @Test("Entry points pass reduction tuning through without dropping search settings")
    func reductionTuningReachesBothEntryPoints() throws {
        let generator = Gen.choose(in: UInt64(0) ... 100)
        let initial: UInt64 = 50
        let tree = try #require(try Interpreters.reflect(generator, with: initial))
        let configuration = Interpreters.ReducerConfiguration(
            maxStalls: 2,
            enabledEncoders: [.valueSearch],
            tuning: ReductionTuning(valueLinearScanThreshold: 0)
        )
        let property: (UInt64) -> Bool = { ($0 >= 20 || $0 == 3) == false }

        let entry = Interpreters.choiceGraphReduceCollectingStats(gen: generator, tree: tree, output: initial, config: configuration, property: property)
        let direct = ReductionSession.reduce(generator: generator, tree: tree, output: initial, configuration: configuration, collectStats: true, property: property)
        let entryResult = try #require(entry.outcome.counterexample)
        let directResult = try #require(direct.outcome.counterexample)

        #expect(entryResult.1 == 20)
        #expect(entryResult.0 == directResult.0)
        #expect(entryResult.1 == directResult.1)
        #expect(entry.stats.encoderProbes == direct.stats.encoderProbes)
    }

    @Test("The non-stats driver retains probe outcome accounting without collecting step timings")
    func uncountedDriver() throws {
        let generator = Gen.choose(in: 0 ... 100)
        let tree = try #require(try Interpreters.reflect(generator, with: 42))
        var propertyCalls = 0
        let result = ReductionSession.reduce(
            generator: generator,
            tree: tree,
            output: 42,
            configuration: .init(maxStalls: 2),
            collectStats: false,
            property: {
                propertyCalls += 1
                return $0 < 7
            }
        )
        #expect(result.outcome.counterexample?.1 == 7)
        #expect(propertyCalls > 0)
        #expect(result.stats.reductionProbesWherePropertyPassed + result.stats.reductionProbesWherePropertyFailed == propertyCalls)
        #expect(result.stats.totalMaterializations == propertyCalls + result.stats.reductionProbesWherePropertyFailed)
        #expect(result.stats.stepTimings.dispatchCount == 0)
        #expect(result.stats.stepTimings.passApplyCount == 0)
        #expect(result.stats.stepTimings.encodeCount == 0)
        #expect(result.stats.stepTimings.decodeCount == 0)
    }
}
