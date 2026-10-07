import Testing
@testable import ExhaustCore

@Suite("Harder higher-order coupling challenges")
struct HigherOrderCouplingChallengeTests {
    @Test("Shifted power curves require every determining coordinate to move", arguments: Coupling.allCases)
    func genuineCoordination(coupling: Coupling) {
        let initial = coupling.counterexample(source: 75)
        let minimum = coupling.counterexample(source: 1)
        #expect(coupling.property(initial) == false)
        #expect(coupling.property(minimum) == false)
        #expect(coupling.property(initial.map { $0 / 2 }))
        #expect(coupling.property(Array(repeating: 1, count: initial.count)))
        let divisor = initial.reduce(UInt64(0)) { ReductionIntegerMath.greatestCommonDivisor($0, UInt64($1)) }
        #expect(divisor == 1)
        // Each coordinate is injective in the positive source, so keeping any coordinate fixes the entire failing tuple.
        for source in 1 ..< 75 {
            let reduced = coupling.counterexample(source: source)
            #expect(coupling.property(reduced) == false)
            #expect(zip(initial, reduced).allSatisfy { $0 != $1 })
        }
        for mask in 1 ..< (1 << initial.count) - 1 {
            let partial = initial.indices.map { index in
                mask & (1 << index) == 0 ? initial[index] : minimum[index]
            }
            #expect(coupling.property(partial))
        }
    }

    @Test("A large coprime three-way curve reduces through mixed proposal ranks")
    func shiftedPowerTriple() throws {
        let coupling = Coupling.shiftedPowers
        let initial = coupling.counterexample(source: 75)
        #expect(initial == [75, 5626, 421_877])
        var machine = try machine(values: initial, property: coupling.property)
        #expect(machine.graph.couplingDependents.isEmpty)
        let accepted = machine.runStagedJointSearch()
        #expect(accepted)
        #expect(machine.output as? [Int] == [1, 2, 3])
        #expect(machine.stats.numericSearchCountsByArity[2]?.accepted == 0)
        #expect(machine.stats.numericSearchCountsByArity[3]?.accepted == 1)
        #expect(machine.stats.numericSearchCountsByArity[4] == nil)
        #expect(machine.stats.encoderCounts[.stagedJointSearch]!.emitted <= 512)
    }

    @Test("Decoys delay an available three-way witness beyond the checkpoint budget")
    func shiftedPowerTripleWithDecoys() throws {
        let coupling = Coupling.shiftedPowers
        let positions = [1, 3, 5]
        let initial = [1, 75, 1, 5626, 1, 421_877]
        var machine = try machine(values: initial) { values in coupling.property(positions.map { values[$0] }) }
        #expect(machine.runStagedJointSearch() == false)
        #expect(machine.output as? [Int] == initial)
        #expect(machine.stats.numericSearchCountsByArity[2]?.accepted == 0)
        #expect(machine.stats.numericSearchCountsByArity[3]?.accepted == 0)
        #expect(machine.stats.encoderCounts[.stagedJointSearch]?.emitted == 512)
        let frontier = NumericJointQuery.frontier(graph: machine.graph, gate: machine.convergence.gate)
        let scope = NumericJointQuery.build(frontier: frontier, graph: machine.graph, arity: 3, workLimit: machine.tuning.threeWayNumericWorkLimit, calculationLimit: 512, scopeLimit: 30)
        var cursor = NumericJointSearchCursor(groups: scope.groups)
        let base = machine.sequence
        var witness: [Int]?
        var ordinal = 0
        for _ in 0 ..< scope.estimatedWork {
            var candidate = base
            guard cursor.next(into: &candidate) != nil else { break }
            ordinal += 1
            let values = decodedValues(candidate)
            let projected = positions.map { values[$0] }
            if coupling.property(projected) == false {
                witness = projected
                break
            }
        }
        #expect(witness == [1, 2, 3])
        #expect(ordinal > machine.stats.numericSearchCountsByArity[3]!.emitted)
    }

    @Test("Four-way remote compensation exposes work gating and missing proposal coverage", arguments: [1024, 1296])
    func conservedSumAndPowers(workLimit: Int) throws {
        let coupling = Coupling.conservedSumAndPowers
        let initial = coupling.counterexample(source: 75)
        #expect(initial == [75, 26, 5626, 421_877])
        #expect(coupling.counterexample(source: 1) == [1, 100, 2, 3])
        var tuning = SchedulerTuning()
        tuning.fourWayNumericWorkLimit = workLimit
        var machine = try machine(values: initial, tuning: tuning, property: coupling.property)
        #expect(machine.runStagedJointSearch() == false)
        #expect(machine.output as? [Int] == initial)
        #expect(machine.stats.numericSearchCountsByArity[2]?.accepted == 0)
        #expect(machine.stats.numericSearchCountsByArity[3]?.accepted == 0)
        #expect((machine.stats.numericSearchCountsByArity[4] != nil) == (workLimit == 1296))
        #expect(machine.stats.encoderCounts[.stagedJointSearch]?.emitted == 512)
    }

    @Test("Even the full sampled four-way grid omits every smaller failing assignment")
    func fourWayCoverageGap() throws {
        let coupling = Coupling.conservedSumAndPowers
        let initial = coupling.counterexample(source: 75)
        let machine = try machine(values: initial, property: coupling.property)
        let frontier = NumericJointQuery.frontier(graph: machine.graph, gate: machine.convergence.gate)
        let scope = NumericJointQuery.build(frontier: frontier, graph: machine.graph, arity: 4, workLimit: 1296, calculationLimit: 512, scopeLimit: 30)
        let group = try #require(scope.groups.first)
        #expect(scope.groups.count == 1)
        #expect(scope.estimatedWork == 1296)
        #expect(group.ratioProposals.isEmpty)
        let requiredCompensation = ChoiceValue(100, tag: .int).bitPattern64
        #expect(group.samples[1].contains(requiredCompensation) == false)
        var cursor = NumericJointSearchCursor(groups: scope.groups)
        let base = machine.sequence
        var emitted = 0
        for _ in 0 ... scope.estimatedWork {
            var candidate = base
            guard cursor.next(into: &candidate) != nil else { break }
            #expect(candidate.shortLexPrecedes(base))
            #expect(coupling.property(decodedValues(candidate)))
            emitted += 1
        }
        #expect(emitted == 1296)
        #expect(coupling.property(coupling.counterexample(source: 1)) == false)
    }

    /// Reflects broad integer domains and settles all leaves so each challenge starts at the same post-cycle checkpoint without historical coupling hints.
    private func machine(values: [Int], tuning: SchedulerTuning = .init(), property: @escaping ([Int]) -> Bool) throws -> ReductionMachine {
        let generator = Gen.eachOf(Array(repeating: Gen.choose(in: 1 ... 1_000_000), count: values.count))
        let tree = try #require(try Interpreters.reflect(generator, with: values))
        var machine = ReductionMachine(gen: generator, initialTree: tree, initialOutput: values, config: .init(maxStalls: 2, enabledEncoders: [.stagedJointSearch], tuning: tuning), collectStats: true, property: property)
        machine.convergence.deferBindInner = false
        for nodeID in machine.graph.leafNodes {
            guard case let .chooseBits(metadata) = machine.graph.nodes[nodeID].kind else { continue }
            machine.graph.convergenceStore[nodeID] = ConvergedOrigin(bound: metadata.value.bitPattern64, signal: .monotoneConvergence, configuration: .binarySearchSemanticSimplest, cycle: 0)
        }
        return machine
    }

    private func decodedValues(_ sequence: ChoiceSequence) -> [Int] {
        sequence.compactMap { $0.value?.choice.decodedSignedValue }.map(Int.init)
    }

    /// Supplies a known minimum and an injective failure curve, rather than a lookup table of two specially chosen assignments. All arithmetic fits `Int64` throughout the declared domains.
    enum Coupling: CaseIterable {
        case shiftedPowers
        case conservedSumAndPowers

        /// Constructs the unique failing tuple for a positive source.
        func counterexample(source: Int) -> [Int] {
            let square = source * source + 1
            let cube = source * source * source + 2
            return switch self {
                case .shiftedPowers:
                    [source, square, cube]
                case .conservedSumAndPowers:
                    [source, 101 - source, square, cube]
            }
        }

        /// Fails only when every coordinate lies on the same shifted power curve.
        func property(_ values: [Int]) -> Bool {
            let source = values[0]
            return switch self {
                case .shiftedPowers:
                    values[1] != source * source + 1 || values[2] != source * source * source + 2
                case .conservedSumAndPowers:
                    source + values[1] != 101 || values[2] != source * source + 1 || values[3] != source * source * source + 2
            }
        }
    }
}
