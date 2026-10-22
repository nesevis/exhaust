import Testing
@testable import ExhaustCore

@Suite("Lazy value search probes")
struct ValueSearchLazyProbeTests {
    @Test(
        "Single-leaf probes leave the buffer untouched and hash exactly like their complete candidates",
        arguments: [false, true]
    )
    func singleLeafCandidates(isFloatingPoint: Bool) throws {
        let fixture = try Fixture(isFloatingPoint: isFloatingPoint)
        var search = fixture.search()
        let base = fixture.incumbent.sequence
        let baseHash = ZobristHash.hash(of: base)
        var untouched: ChoiceSequence = [.just]
        var feedback = SearchFeedback.initial
        var count = 0
        while let candidate = search.next(feedback, into: &untouched) {
            let probe = try requireLazy(candidate)
            #expect(untouched == [.just])
            var materialized = base
            probe.write(into: &materialized)
            #expect(probe.hash(baseHash: baseHash, baseSequence: base) == ZobristHash.hash(of: materialized))
            let changed = base.indices.filter { base[$0] != materialized[$0] }
            #expect(changed.count == 1)
            if case let .leafValues(changes) = candidate.mutation {
                #expect(changes.count == 1)
                let change = try #require(changes.first)
                let position = try #require(fixture.graph.nodes[change.leafNodeID].positionRange).lowerBound
                #expect(changed == [position])
                #expect(change.newValue == materialized[position].value?.choice)
            } else {
                Issue.record("A leaf probe must report its value change")
            }
            probe.restore(into: &materialized, baseSequence: base)
            #expect(materialized == base)
            count += 1
            feedback = .rejected(.propertyPassed)
        }
        #expect(count > 3)
    }

    @Test(
        "An observed cache hit reproduces the uncached candidate stream across leaves",
        arguments: [false, true]
    )
    func cachedObserverStream(isFloatingPoint: Bool) throws {
        let fixture = try Fixture(isFloatingPoint: isFloatingPoint)
        var firstStream: [ChoiceSequence] = []
        let first = fixture.run(cache: []) { observation in
            if case let .emitted(_, sequence, _) = observation {
                firstStream.append(sequence)
            }
        }
        var cachedStream: [ChoiceSequence] = []
        let cached = fixture.run(cache: first.rejectCache) { observation in
            if case let .emitted(_, sequence, _) = observation {
                cachedStream.append(sequence)
            }
        }
        #expect(firstStream.isEmpty == false)
        #expect(cachedStream == firstStream)
        #expect(cached.report.counts.rejectedByCache == cached.report.counts.emitted)
        #expect(cached.report.counts.materializationAttempts == 0)
        #expect(cached.incumbent.sequence == fixture.incumbent.sequence)
    }

    @Test("Float acceptance preserves the decoder's adjusted value when moving to the next leaf")
    func floatRecoveredBaseline() throws {
        let fixture = try Fixture(isFloatingPoint: true)
        var search = fixture.search()
        var buffer: ChoiceSequence = []
        let first = try #require(search.next(.initial, into: &buffer))
        let firstProbe = try requireLazy(first)
        var recovered = fixture.incumbent.sequence
        firstProbe.write(into: &recovered)
        let firstPosition = try #require(
            fixture.graph.nodes[fixture.graph.leafNodes[0]].positionRange
        ).lowerBound
        recovered[firstPosition] = recovered[firstPosition].withBitPattern(
            ChoiceValue(1.25, tag: .double).bitPattern64
        )

        let next = try #require(search.next(.accepted(recovered: recovered), into: &buffer))
        let nextProbe = try requireLazy(next)
        var candidate = recovered
        nextProbe.write(into: &candidate)
        #expect(candidate[firstPosition] == recovered[firstPosition])
        #expect(
            nextProbe.hash(baseHash: ZobristHash.hash(of: recovered), baseSequence: recovered)
                == ZobristHash.hash(of: candidate)
        )
        #expect(search.next(.accepted(recovered: []), into: &buffer) == nil)
    }

    // MARK: - Test Helpers

    private func requireLazy(_ candidate: ReductionCandidate) throws -> SequencePatch {
        guard case let .lazy(probe) = candidate.contents else {
            throw LazyExpected()
        }
        return probe
    }

    private struct LazyExpected: Error {}

    private struct Fixture {
        let isFloatingPoint: Bool
        let generator: AnyGenerator
        let incumbent: Counterexample
        let graph: ChoiceGraph

        init(isFloatingPoint: Bool) throws {
            self = switch isFloatingPoint {
                case true:
                    try Fixture(
                        generator: Gen.arrayOf(Gen.choose(in: -100.0 ... 100.0), exactly: 3),
                        values: [-37.125, 12.5, 4.25],
                        isFloatingPoint: true
                    )
                case false:
                    try Fixture(
                        generator: Gen.arrayOf(Gen.choose(in: Int64(-100) ... 100), exactly: 3),
                        values: [-50, 50, 7],
                        isFloatingPoint: false
                    )
            }
        }

        private init<Value>(
            generator: Generator<[Value]>,
            values: [Value],
            isFloatingPoint: Bool
        ) throws {
            self.isFloatingPoint = isFloatingPoint
            self.generator = generator.erase()
            let tree = try #require(try Interpreters.reflect(generator, with: values))
            incumbent = Counterexample(sequence: ChoiceSequence(tree), tree: tree, output: values)
            graph = ChoiceGraph.build(from: tree)
        }

        /// Bypasses integer batch probes so both fixtures exercise the single-leaf candidate contract.
        func search() -> any ReductionSearch {
            let leaves = graph.leafNodes.map { LeafEntry(nodeID: $0) }
            if isFloatingPoint {
                return FloatSearch(
                    scope: FloatMinimizationScope(leaves: leaves),
                    sequence: incumbent.sequence,
                    graph: graph
                )
            }
            return IntegerSearch(
                scope: ValueMinimizationScope(leaves: leaves, batchZeroEligible: false),
                sequence: incumbent.sequence,
                graph: graph,
                warmStarts: [:],
                tuning: .init()
            )
        }

        /// Rejects every decoded candidate so a second run can replay the entire stream from the first run's cache.
        func run(cache: ProbeCache, observer: @escaping (ProbeObservation) -> Void) -> Reducer.Result {
            Reducer.reduce(.search(search(), configuration: .standard), context: Reducer.Context(
                incumbent: incumbent,
                incumbentHash: ZobristHash.hash(of: incumbent.sequence),
                graph: graph,
                rejectCache: cache,
                decoder: ReductionDecoder(
                    generator: generator,
                    property: { _ in true },
                    probeWrapper: nil,
                    hasBind: false
                ),
                encoder: isFloatingPoint ? FloatSearchEncoder.self : ValueSearchEncoder.self,
                observer: observer
            ))
        }
    }
}
