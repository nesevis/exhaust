import Testing
@testable import ExhaustCore

@Suite("Staged joint numeric search")
struct StagedJointSearchTests {
    @Test("Character pairs, triples, and quadruples never enter staged joint search", arguments: [2, 3, 4])
    func excludesCharacterScopes(arity: Int) throws {
        let generator = Gen.eachOf(Array(repeating: Gen.character(in: "a" ... "z").gen, count: arity))
        let initial = Array(repeating: Character("z"), count: arity)
        let tree = try #require(try Interpreters.reflect(generator, with: initial))
        var machine = ReductionMachine(
            gen: generator,
            initialTree: tree,
            initialOutput: initial,
            config: .init(maxStalls: 2, enabledEncoders: [.stagedJointSearch]),
            collectStats: true,
            property: { values in values.contains { $0 != values[0] } }
        )
        machine.convergence.deferBindInner = false
        markConverged(&machine.graph)
        #expect(machine.pendingStagedNumericPairs() == nil)
        let accepted = machine.runStagedJointSearch()
        #expect(accepted == false)
        #expect(machine.stats.encoderCounts[.stagedJointSearch] == nil)
        #expect(machine.output as? [Character] == initial)
    }

    @Test("Numeric triples and quadruples shrink alongside untouched characters", arguments: [3, 4])
    func numericStagesExcludeCharacters(arity: Int) throws {
        let text = Gen.eachOf(Array(repeating: Gen.character(in: "a" ... "z").gen, count: 2))
        let numbers = Gen.eachOf(Array(repeating: Gen.choose(in: 1 ... 1000), count: arity))
        let generator = Gen.zip(text, numbers)
        let initial: ([Character], [Int]) = (["z", "z"], arity == 3 ? [6, 8, 10] : [2, 4, 6, 10])
        let tree = try #require(try Interpreters.reflect(generator, with: initial))
        var sawCharacterProbe = false
        var machine = ReductionMachine(
            gen: generator,
            initialTree: tree,
            initialOutput: initial,
            config: .init(maxStalls: 2, enabledEncoders: [.stagedJointSearch]),
            collectStats: true,
            property: { values in
                if values.0 != initial.0 { sawCharacterProbe = true }
                let numbers = values.1
                let numericPasses = arity == 3
                    ? numbers[0] * numbers[0] + numbers[1] * numbers[1] != numbers[2] * numbers[2]
                    : numbers[1] != 2 * numbers[0] || numbers[2] != 3 * numbers[0] || numbers[3] != 5 * numbers[0]
                return values.0[0] != values.0[1] || numericPasses
            }
        )
        machine.convergence.deferBindInner = false
        markConverged(&machine.graph)
        let accepted = machine.runStagedJointSearch()
        #expect(accepted)
        let output = try #require(machine.output as? ([Character], [Int]))
        #expect(output.0 == initial.0)
        #expect(output.1 == (arity == 3 ? [3, 4, 5] : [1, 2, 3, 5]))
        #expect(machine.stats.numericSearchCountsByArity[2]?.accepted == 0)
        #expect(machine.stats.numericSearchCountsByArity[arity]?.accepted == 1)
        #expect(sawCharacterProbe == false)
    }

    @Test("A long character sequence cannot consume the numeric leaf or frontier caps")
    func separateFrontierCaps() throws {
        let character = try #require(try Interpreters.reflect(Gen.character(in: "a" ... "z").gen, with: "z"))
        let count = NumericPairQuery.maximumLeaves + 44
        let text = ChoiceTree.sequence(elements: Array(repeating: character, count: count), metadata: .init(validRange: UInt64(count) ... UInt64(count), isRangeExplicit: true))
        let numbers = ChoiceTree.group([6, 8, 10].map { .choice(ChoiceValue(UInt64($0), tag: .uint64), .init(validRange: 1 ... 1000, isRangeExplicit: true)) })
        var graph = ChoiceGraph.build(from: .group([text, numbers]))
        markConverged(&graph)
        let gate = BoundValueGate(baseBudget: 15)
        #expect(NumericPairQuery.eligibleLeaves(graph: graph).count == 3)
        #expect(NumericJointQuery.frontier(graph: graph, gate: gate).count == 3)
    }

    @Test("Pair-only float scopes skip the joint frontier without suppressing pair search", arguments: [TypeTag.float16, .float, .double], [1, 2])
    func pairOnlyFloatingFrontier(tag: TypeTag, count: Int) {
        let range = tag.floatingBitPattern(from: -16) ... tag.floatingBitPattern(from: 16)
        let values: [ChoiceTree] = (0 ..< count).map { _ in
            .choice(ChoiceValue(tag.floatingBitPattern(from: 8), tag: tag), .init(validRange: range, isRangeExplicit: true))
        }
        // Fixed domains, booleans, and nonfinite floats cannot supply a third coordinate.
        let excluded: [ChoiceTree] = [
            .choice(ChoiceValue(UInt64(8), tag: .uint64), .init(validRange: 8 ... 8, isRangeExplicit: true)),
            .choice(ChoiceValue(UInt8(1), tag: .uint8), .init(validRange: 0 ... 1, isRangeExplicit: true)),
            .choice(ChoiceValue(tag.floatingBitPattern(from: .infinity), tag: tag), .init(validRange: tag.bitPatternRange, isRangeExplicit: true)),
        ]
        var graph = ChoiceGraph.build(from: .group(values + excluded))
        markConverged(&graph)
        let gate = BoundValueGate(baseBudget: 15)
        #expect(NumericPairQuery.eligibleLeaves(graph: graph).count == count + 1)
        #expect(NumericJointQuery.frontier(graph: graph, gate: gate).isEmpty)
        if count == 2 {
            #expect(NumericPairQuery.build(graph: graph, gate: gate).contains {
                $0.source.choice.tag == tag && $0.sink.choice.tag == tag
            })
        }
    }

    @Test("Floating triples and quadruples require every coordinate to change", arguments: [3, 4], [false, true])
    func floatingJointSearch(arity: Int, negative: Bool) throws {
        let initial = Array(repeating: negative ? -8.0 : 8.0, count: arity)
        let generator = Gen.eachOf(Array(repeating: Gen.choose(in: -16.0 ... 16.0), count: arity))
        let tree = try #require(try Interpreters.reflect(generator, with: initial))
        var machine = ReductionMachine(
            gen: generator,
            initialTree: tree,
            initialOutput: initial,
            config: .init(maxStalls: 2, enabledEncoders: [.stagedJointSearch], tuning: .init(fourWayNumericWorkLimit: 1296)),
            collectStats: true,
            property: { values in values.contains { $0 != values[0] } }
        )
        machine.convergence.deferBindInner = false
        markConverged(&machine.graph)
        let accepted = machine.runStagedJointSearch()
        #expect(accepted)
        #expect(machine.output as? [Double] == Array(repeating: 0.0, count: arity))
        for lowerArity in 2 ..< arity {
            #expect(machine.stats.numericSearchCountsByArity[lowerArity]?.accepted == 0)
        }
        #expect(machine.stats.numericSearchCountsByArity[arity]?.accepted == 1)
        #expect(machine.stats.encoderCounts[.stagedJointSearch]!.emitted <= 512)
        #expect(ChoiceSequence(machine.tree) == machine.sequence)
    }

    @Test("Floating joint search scales proportional tuples semantically", arguments: [3, 4])
    func floatingRescaling(arity: Int) throws {
        let initial = Array([8.0, 16.0, 24.0, 40.0].prefix(arity))
        let generator = Gen.eachOf(Array(repeating: Gen.choose(in: 1.0 ... 1000.0), count: arity))
        let tree = try #require(try Interpreters.reflect(generator, with: initial))
        var machine = ReductionMachine(
            gen: generator,
            initialTree: tree,
            initialOutput: initial,
            config: .init(maxStalls: 2, enabledEncoders: [.stagedJointSearch], tuning: .init(fourWayNumericWorkLimit: 1296)),
            collectStats: true,
            property: { values in values.indices.contains { values[$0] * initial[0] != values[0] * initial[$0] } }
        )
        machine.convergence.deferBindInner = false
        markConverged(&machine.graph)
        let accepted = machine.runStagedJointSearch()
        #expect(accepted)
        #expect(machine.output as? [Double] == initial.map { $0 / 2 })
        #expect(machine.stats.numericSearchCountsByArity[arity]?.accepted == 1)
    }

    @Test("Floating palettes use semantic halves and admit only finite domain values", arguments: [TypeTag.float16, .float, .double])
    func floatingFrontier(tag: TypeTag) {
        let range = tag.floatingBitPattern(from: -16) ... tag.floatingBitPattern(from: 16)
        let tree = ChoiceTree.group([8.0, -8.0, 0.0].map { value in
            .choice(ChoiceValue(tag.floatingBitPattern(from: value), tag: tag), .init(validRange: range, isRangeExplicit: true))
        })
        var graph = ChoiceGraph.build(from: tree)
        markConverged(&graph)
        let frontier = NumericJointQuery.frontier(graph: graph, gate: .init(baseBudget: 15))
        #expect(frontier.count == 3)
        for entry in frontier {
            let current = entry.leaf.choice.decodedDoubleValue
            if current != 0 {
                let values = entry.simplifyingSamples.map { ChoiceValue($0, tag: tag).decodedDoubleValue }
                #expect(values.prefix(2).elementsEqual([0, current / 2]))
            }
            for pattern in entry.simplifyingSamples + entry.compensatingSamples {
                #expect(range.contains(pattern))
                #expect(ChoiceValue(pattern, tag: tag).decodedDoubleValue.isFinite)
            }
        }
        let nonfiniteTree = ChoiceTree.group([Double.infinity, -Double.infinity, Double.nan].map { value in
            .choice(ChoiceValue(tag.floatingBitPattern(from: value), tag: tag), .init(validRange: tag.bitPatternRange, isRangeExplicit: true))
        })
        #expect(NumericJointQuery.frontier(graph: ChoiceGraph.build(from: nonfiniteTree), gate: .init(baseBudget: 15)).isEmpty)
    }

    @Test("Joint groups can mix integers and floating-point widths without integer rescaling")
    func mixedFloatingTriple() throws {
        let generator = Gen.zip(Gen.choose(in: 1.0 ... 16.0), Gen.choose(in: Float(1) ... 16), Gen.choose(in: Int8(1) ... 16))
        let initial = (8.0, Float(8), Int8(8))
        let tree = try #require(try Interpreters.reflect(generator, with: initial))
        var machine = ReductionMachine(
            gen: generator,
            initialTree: tree,
            initialOutput: initial,
            config: .init(maxStalls: 2, enabledEncoders: [.stagedJointSearch]),
            collectStats: true,
            property: { values in values.0 != Double(values.1) || values.0 != Double(values.2) }
        )
        machine.convergence.deferBindInner = false
        markConverged(&machine.graph)
        let frontier = NumericJointQuery.frontier(graph: machine.graph, gate: machine.convergence.gate)
        let scope = NumericJointQuery.build(frontier: frontier, graph: machine.graph, arity: 3, workLimit: 4096, calculationLimit: 512, scopeLimit: 30)
        #expect(scope.groups.count == 1)
        #expect(scope.groups[0].ratioProposals.isEmpty)
        let accepted = machine.runStagedJointSearch()
        #expect(accepted)
        let output = try #require(machine.output as? (Double, Float, Int8))
        #expect(output.0 == 1 && output.1 == 1 && output.2 == 1)
        #expect(machine.stats.numericSearchCountsByArity[2]?.accepted == 0)
        #expect(machine.stats.numericSearchCountsByArity[3]?.accepted == 1)
    }

    @Test("Pythagorean triples shrink inside zips with unrelated slots", arguments: [3, 4, 5, 6])
    func pythagoreanZips(count: Int) throws {
        for positions in determiningTriples(count: count) {
            var initial = Array(repeating: 1, count: count)
            for (position, value) in zip(positions, [6, 8, 10]) {
                initial[position] = value
            }
            let generator = Gen.eachOf(Array(repeating: Gen.choose(in: 1 ... 1_000_000), count: count))
            let tree = try #require(try Interpreters.reflect(generator, with: initial))
            var machine = ReductionMachine(
                gen: generator,
                initialTree: tree,
                initialOutput: initial,
                config: .init(maxStalls: 2, enabledEncoders: [.valueSearch, .stagedJointSearch]),
                collectStats: true,
                property: { values in
                    let first = values[positions[0]]
                    let second = values[positions[1]]
                    let third = values[positions[2]]
                    return first * first + second * second != third * third
                }
            )
            finish(&machine)
            let output = try #require(machine.output as? [Int])
            #expect(positions.map { output[$0] } == [3, 4, 5])
            #expect(machine.stats.numericSearchCountsByArity[2]?.accepted == 0)
            #expect((machine.stats.numericSearchCountsByArity[3]?.accepted ?? 0) > 0)
            #expect(machine.stats.numericSearchCountsByArity[4] == nil)
        }
    }

    @Test("Common-divisor proposals minimize large Pythagorean triples in every zip placement", arguments: [3, 4, 5, 6])
    func largePythagoreanZips(count: Int) throws {
        for positions in determiningTriples(count: count) {
            var initial = Array(repeating: 1, count: count)
            for (position, value) in zip(positions, [300, 400, 500]) {
                initial[position] = value
            }
            var machine = try machine(values: initial, enabledEncoders: [.valueSearch, .stagedJointSearch]) { values in
                let first = values[positions[0]]
                let second = values[positions[1]]
                let third = values[positions[2]]
                return first * first + second * second != third * third
            }
            let accepted = machine.runStagedJointSearch()
            #expect(accepted)
            let reduced = try #require(machine.output as? [Int])
            #expect(positions.map { reduced[$0] } == [3, 4, 5])
            #expect(machine.stats.numericSearchCountsByArity[2]?.accepted == 0)
            #expect(machine.stats.numericSearchCountsByArity[3]?.accepted == 1)
            #expect(machine.stats.numericSearchCountsByArity[3]?.emitted == 1)
            #expect(machine.stats.encoderCounts[.stagedJointSearch]!.emitted <= 512)
            finish(&machine)
            let output = try #require(machine.output as? [Int])
            #expect(positions.map { output[$0] } == [3, 4, 5])
            #expect(machine.stats.numericSearchCountsByArity[4] == nil)
        }
    }

    @Test("Four-way coupling escalates only after pairs and triples fail", arguments: [false, true])
    func fourWayCoupling(nonlinear: Bool) throws {
        let initial = nonlinear ? [2, 4, 5, 6] : [2, 4, 6, 10]
        var observedArities: [Int] = []
        var machine = try machine(values: initial) { values in
            observedArities.append(zip(values, initial).count(where: { $0.0 != $0.1 }))
            if nonlinear {
                return values[1] != values[0] * values[0]
                    || values[2] != 2 * values[0] + 1
                    || values[3] != values[0] * values[0] + values[0]
            }
            return values[1] != 2 * values[0] || values[2] != 3 * values[0] || values[3] != 5 * values[0]
        }
        let accepted = machine.runStagedJointSearch()
        #expect(accepted)
        #expect(machine.output as? [Int] == (nonlinear ? [1, 1, 3, 2] : [1, 2, 3, 5]))
        #expect(machine.stats.numericSearchCountsByArity[2]?.accepted == 0)
        #expect(machine.stats.numericSearchCountsByArity[3]?.accepted == 0)
        #expect(machine.stats.numericSearchCountsByArity[4]?.accepted == 1)
        #expect(observedArities == observedArities.sorted())
        #expect(machine.stats.encoderCounts[.stagedJointSearch]!.emitted <= 512)
        #expect(machine.graph.convergenceStore.isEmpty)
        #expect(machine.rejectCache.isEmpty)
    }

    @Test("A common divisor resolves a proportional pair on the first staged probe")
    func commonDivisorPair() throws {
        let tuning = SchedulerTuning(stagedJointProbeBudget: 1)
        var machine = try machine(values: [75, 100], tuning: tuning) { $0[0] * 4 != $0[1] * 3 }
        let accepted = machine.runStagedJointSearch()
        #expect(accepted)
        #expect(machine.output as? [Int] == [3, 4])
        #expect(machine.stats.encoderCounts[.stagedJointSearch]?.emitted == 1)
        #expect(machine.stats.numericSearchCountsByArity[2]?.accepted == 1)
        #expect(machine.stats.numericSearchCountsByArity[3] == nil)
        #expect(machine.stats.encoderCounts[.pairwiseNumericSearch] == nil)
    }

    @Test("A common divisor directly escapes the Pythagorean sampling plateau")
    func commonDivisorPlateau() throws {
        var machine = try machine(values: [75, 100, 125]) { $0[0] * $0[0] + $0[1] * $0[1] != $0[2] * $0[2] }
        let accepted = machine.runStagedJointSearch()
        #expect(accepted)
        #expect(machine.output as? [Int] == [3, 4, 5])
        #expect(machine.stats.numericSearchCountsByArity[2]?.accepted == 0)
        #expect(machine.stats.numericSearchCountsByArity[3]?.emitted == 1)
        #expect(machine.stats.numericSearchCountsByArity[3]?.accepted == 1)
    }

    @Test("Three-way work threshold is inclusive and zero disables escalation", arguments: [0, 179, 180])
    func threeWayThreshold(limit: Int) throws {
        var tuning = SchedulerTuning()
        tuning.threeWayNumericWorkLimit = limit
        var machine = try machine(values: [6, 8, 10], tuning: tuning) { $0[0] * $0[0] + $0[1] * $0[1] != $0[2] * $0[2] }
        #expect(machine.runStagedJointSearch() == (limit == 180))
        #expect((machine.stats.numericSearchCountsByArity[3] != nil) == (limit == 180))
        #expect(machine.stats.numericSearchCountsByArity[4] == nil)
    }

    @Test("Four-way work threshold applies after three-way failure", arguments: [0, 215, 216])
    func fourWayThreshold(limit: Int) throws {
        var tuning = SchedulerTuning()
        tuning.fourWayNumericWorkLimit = limit
        var machine = try machine(values: [2, 4, 6, 10], tuning: tuning) { $0[1] != 2 * $0[0] || $0[2] != 3 * $0[0] || $0[3] != 5 * $0[0] }
        #expect(machine.runStagedJointSearch() == (limit == 216))
        #expect(machine.stats.numericSearchCountsByArity[3] != nil)
        #expect((machine.stats.numericSearchCountsByArity[4] != nil) == (limit == 216))
    }

    @Test("A successful pair prevents higher stages")
    func pairAcceptanceStopsEscalation() throws {
        var machine = try machine(values: [3, 1, 1]) { $0[0] + $0[1] != 4 }
        let accepted = machine.runStagedJointSearch()
        #expect(accepted)
        #expect(machine.stats.numericSearchCountsByArity[2]?.accepted == 1)
        #expect(machine.stats.numericSearchCountsByArity[3] == nil)
        #expect(machine.stats.numericSearchCountsByArity[4] == nil)
    }

    @Test("All stages share a budget and do not repeat an exhausted checkpoint", arguments: [1, 7, 32, 512])
    func sharedBudget(budget: Int) throws {
        let initial = [2, 4, 6, 10]
        var tuning = SchedulerTuning()
        tuning.stagedJointProbeBudget = budget
        var machine = try machine(values: initial, tuning: tuning) { $0 != initial }
        #expect(machine.runStagedJointSearch() == false)
        let counts = try #require(machine.stats.encoderCounts[.stagedJointSearch])
        #expect(counts.emitted <= budget)
        #expect(machine.stats.numericSearchCountsByArity.values.reduce(0) { $0 + $1.emitted } == counts.emitted)
        #expect(machine.pendingStagedNumericPairs() == nil)
        #expect(machine.runStagedJointSearch() == false)
        #expect(machine.stats.encoderCounts[.stagedJointSearch] == counts)
    }

    @Test("Large decoys retain lower priority than the determining group")
    func largeDecoys() throws {
        let initial = [1_000_000, 6, 1_000_000, 8, 1_000_000, 10]
        var machine = try machine(values: initial) { $0[1] * $0[1] + $0[3] * $0[3] != $0[5] * $0[5] }
        let valuePositions = machine.sequence.indices.filter { machine.sequence[$0].value != nil }
        for position in [0, 2, 4] {
            let nodeID = try #require(machine.graph.leafNodes.first { machine.graph.nodes[$0].positionRange?.lowerBound == valuePositions[position] })
            machine.graph.clearConvergence(nodeID)
        }
        let accepted = machine.runStagedJointSearch()
        #expect(accepted)
        let output = try #require(machine.output as? [Int])
        #expect([output[1], output[3], output[5]] == [3, 4, 5])
        #expect([output[0], output[2], output[4]] == [1_000_000, 1_000_000, 1_000_000])
    }

    @Test("Pairwise and staged encoders can be selected independently for A/B testing", arguments: [EncoderName.pairwiseNumericSearch, .stagedJointSearch])
    func independentEncoderSelection(encoder: EncoderName) throws {
        let initial = [6, 8, 10]
        var machine = try machine(values: initial, enabledEncoders: [.valueSearch, encoder]) {
            $0[0] * $0[0] + $0[1] * $0[1] != $0[2] * $0[2]
        }
        finish(&machine)
        #expect(machine.output as? [Int] == (encoder == .stagedJointSearch ? [3, 4, 5] : initial))
        #expect((machine.stats.encoderCounts[encoder]?.emitted ?? 0) > 0)
        let other: EncoderName = encoder == .stagedJointSearch ? .pairwiseNumericSearch : .stagedJointSearch
        #expect(machine.stats.encoderCounts[other] == nil)
        #expect(machine.stats.numericSearchCountsByArity.isEmpty == (encoder == .pairwiseNumericSearch))
    }

    @Test("Numeric encoders retain independent checkpoint budgets and exhaustion")
    func independentBudgetsAndExhaustion() throws {
        let initial = [2, 4, 6, 10]
        let tuning = SchedulerTuning(pairwiseNumericProbeBudget: 7, stagedJointProbeBudget: 32)
        var machine = try machine(values: initial, tuning: tuning, enabledEncoders: [.pairwiseNumericSearch, .stagedJointSearch]) { $0 != initial }
        #expect(machine.runPairwiseNumericSearch() == false)
        let pairCounts = try #require(machine.stats.encoderCounts[.pairwiseNumericSearch])
        #expect(pairCounts.emitted == 7)
        #expect(machine.pendingNumericPairs() == nil)
        #expect(machine.pendingStagedNumericPairs() != nil)
        #expect(machine.stats.numericSearchCountsByArity.isEmpty)
        #expect(machine.runStagedJointSearch() == false)
        let stagedCounts = try #require(machine.stats.encoderCounts[.stagedJointSearch])
        #expect(stagedCounts.emitted == 32)
        #expect(machine.stats.numericSearchCountsByArity.values.reduce(0) { $0 + $1.emitted } == stagedCounts.emitted)
        #expect(machine.stats.encoderCounts[.pairwiseNumericSearch] == pairCounts)
        #expect(machine.pendingStagedNumericPairs() == nil)
        #expect(machine.runPairwiseNumericSearch() == false)
        #expect(machine.runStagedJointSearch() == false)
        #expect(machine.stats.encoderCounts[.pairwiseNumericSearch] == pairCounts)
        #expect(machine.stats.encoderCounts[.stagedJointSearch] == stagedCounts)
    }

    @Test("Zeroing either numeric budget leaves the other search eligible", arguments: [EncoderName.pairwiseNumericSearch, .stagedJointSearch])
    func independentBudgetDisable(disabled: EncoderName) throws {
        let tuning = SchedulerTuning(
            pairwiseNumericProbeBudget: disabled == .pairwiseNumericSearch ? 0 : 512,
            stagedJointProbeBudget: disabled == .stagedJointSearch ? 0 : 512
        )
        let initial = [2, 4, 6, 10]
        var machine = try machine(values: initial, tuning: tuning, enabledEncoders: [.pairwiseNumericSearch, .stagedJointSearch]) { $0 != initial }
        #expect((machine.pendingNumericPairs() == nil) == (disabled == .pairwiseNumericSearch))
        #expect((machine.pendingStagedNumericPairs() == nil) == (disabled == .stagedJointSearch))
        #expect(machine.runPairwiseNumericSearch() == false)
        #expect(machine.runStagedJointSearch() == false)
        #expect(machine.stats.encoderCounts[disabled] == nil)
        let other: EncoderName = disabled == .stagedJointSearch ? .pairwiseNumericSearch : .stagedJointSearch
        #expect((machine.stats.encoderCounts[other]?.emitted ?? 0) > 0)
    }

    @Test("Higher-order grids enumerate unique improving tuples", arguments: [3, 4])
    func uniqueGrid(arity: Int) {
        let tree = unsignedTree(values: Array(repeating: 3, count: arity), range: 0 ... 3)
        var graph = ChoiceGraph.build(from: tree)
        markConverged(&graph)
        let frontier = NumericJointQuery.frontier(graph: graph, gate: .init(baseBudget: 15))
        let scope = NumericJointQuery.build(frontier: frontier, graph: graph, arity: arity, workLimit: 4096, calculationLimit: 512, scopeLimit: 30)
        #expect(scope.groups.count == 1)
        var cursor = NumericJointSearchCursor(groups: scope.groups)
        let base = ChoiceSequence(tree)
        var observed: Set<[UInt64]> = []
        for _ in 0 ..< 100 {
            var candidate = base
            guard let proposal = cursor.next(into: &candidate) else { break }
            #expect(proposal.leaves.count == arity)
            #expect(candidate.shortLexPrecedes(base))
            #expect(observed.insert(proposal.patterns).inserted)
        }
        #expect(observed.count == (arity == 3 ? 27 : 81))
        var candidate = base
        #expect(cursor.next(into: &candidate) == nil)
    }

    @Test("Discovery and retention have independent bounds; coupling hints influence ranking")
    func boundedRanking() {
        var graph = ChoiceGraph.build(from: unsignedTree(values: Array(repeating: 2, count: 12), range: 0 ... UInt64.max))
        markConverged(&graph)
        let frontier = NumericJointQuery.frontier(graph: graph, gate: .init(baseBudget: 15))
        let preferred = Array(frontier.suffix(3).map(\.leaf.nodeID))
        graph.couplingDependents[preferred[0]] = Set(preferred.dropFirst())
        let ranked = NumericJointQuery.build(frontier: frontier, graph: graph, arity: 3, workLimit: 4096, calculationLimit: 512, scopeLimit: 1)
        #expect(ranked.calculations == 220)
        #expect(ranked.groups.count == 1)
        #expect(ranked.groups.first?.leaves.map(\.nodeID) == preferred)
        let bounded = NumericJointQuery.build(frontier: frontier, graph: graph, arity: 3, workLimit: 4096, calculationLimit: 7, scopeLimit: 3)
        #expect(bounded.calculations == 7)
        #expect(bounded.groups.count == 3)
    }

    @Test("Full-width residual volumes saturate for ranking while sampled work gates eligibility")
    func fullWidthGate() throws {
        let tree = unsignedTree(values: [UInt64.max, UInt64.max - 1, UInt64.max - 2, UInt64.max - 3], range: 0 ... UInt64.max)
        var graph = ChoiceGraph.build(from: tree)
        markConverged(&graph)
        let frontier = NumericJointQuery.frontier(graph: graph, gate: .init(baseBudget: 15))
        #expect(NumericJointQuery.canEscalate(frontier: frontier, arity: 3, workLimit: 215) == false)
        #expect(NumericJointQuery.canEscalate(frontier: frontier, arity: 3, workLimit: 216))
        #expect(NumericJointQuery.build(frontier: frontier, graph: graph, arity: 4, workLimit: 1295, calculationLimit: 512, scopeLimit: 30).groups.isEmpty)
        let scope = NumericJointQuery.build(frontier: frontier, graph: graph, arity: 4, workLimit: 1296, calculationLimit: 512, scopeLimit: 30)
        let group = try #require(scope.groups.first)
        #expect(scope.groups.count == 1)
        #expect(scope.estimatedWork == 1296)
        #expect(group.residualVolume == UInt64.max)
        var cursor = NumericJointSearchCursor(groups: scope.groups)
        let base = ChoiceSequence(tree)
        var candidate = base
        #expect(cursor.next(into: &candidate) != nil)
        #expect(candidate.shortLexPrecedes(base))
    }

    @Test("Early discovery rejections still consume the bounded combination prefix", arguments: [3, 4])
    func rejectedCombinationPrefix(arity: Int) {
        var graph = ChoiceGraph.build(from: unsignedTree(values: [0, 3, 3, 3, 3, 3], range: 0 ... 3))
        markConverged(&graph)
        var frontier = NumericJointQuery.frontier(graph: graph, gate: .init(baseBudget: 15))
        let rejected = NumericJointQuery.build(frontier: frontier, graph: graph, arity: arity, workLimit: 4096, calculationLimit: 10, scopeLimit: 30)
        #expect(rejected.calculations == 10)
        #expect(rejected.groups.isEmpty)
        let firstEligible = NumericJointQuery.build(frontier: frontier, graph: graph, arity: arity, workLimit: 4096, calculationLimit: 11, scopeLimit: 30)
        #expect(firstEligible.calculations == 11)
        #expect(firstEligible.groups.count == 1)
        #expect(firstEligible.groups.first?.leaves.map(\.nodeID) == Array(frontier[1 ... arity].map(\.leaf.nodeID)))
        let source = frontier[1]
        frontier[1] = .init(leaf: source.leaf, stalled: source.stalled, span: source.span, simplifyingSamples: [], compensatingSamples: source.compensatingSamples)
        let emptyPalette = NumericJointQuery.build(frontier: frontier, graph: graph, arity: arity, workLimit: 4096, calculationLimit: 11, scopeLimit: 30)
        #expect(emptyPalette.calculations == 11)
        #expect(emptyPalette.groups.isEmpty)
    }

    @Test("Retained grids fit the total work limit rather than only a per-group limit", arguments: [3, 4])
    func totalScopeWork(arity: Int) {
        let tree = unsignedTree(values: Array(repeating: 3, count: 6), range: 0 ... 3)
        var graph = ChoiceGraph.build(from: tree)
        markConverged(&graph)
        let frontier = NumericJointQuery.frontier(graph: graph, gate: .init(baseBudget: 15))
        let perGroup = arity == 3 ? 27 : 81
        let allGroups = arity == 3 ? 20 : 15
        let complete = NumericJointQuery.build(frontier: frontier, graph: graph, arity: arity, workLimit: Int.max, calculationLimit: 512, scopeLimit: 30)
        #expect(complete.groups.count == allGroups)
        #expect(complete.estimatedWork == allGroups * perGroup)
        let bounded = NumericJointQuery.build(frontier: frontier, graph: graph, arity: arity, workLimit: 2 * perGroup, calculationLimit: 512, scopeLimit: 30)
        #expect(bounded.groups.count == 2)
        #expect(bounded.estimatedWork == 2 * perGroup)
        #expect(bounded.calculations == allGroups)
        var cursor = NumericJointSearchCursor(groups: bounded.groups)
        let base = ChoiceSequence(tree)
        var emitted = 0
        for _ in 0 ... bounded.estimatedWork {
            var candidate = base
            guard cursor.next(into: &candidate) != nil else { break }
            #expect(candidate.shortLexPrecedes(base))
            emitted += 1
        }
        #expect(emitted == bounded.estimatedWork)
        let belowOne = NumericJointQuery.build(frontier: frontier, graph: graph, arity: arity, workLimit: perGroup - 1, calculationLimit: 512, scopeLimit: 30)
        #expect(belowOne.calculations == allGroups)
        #expect(belowOne.groups.isEmpty)
        #expect(belowOne.estimatedWork == 0)
    }

    @Test("Residual magnitude ranks affordable groups without excluding larger ones")
    func residualRanking() {
        var graph = ChoiceGraph.build(from: unsignedTree(values: [300, 6, 8, 10], range: 1 ... 1_000_000))
        markConverged(&graph)
        let frontier = NumericJointQuery.frontier(graph: graph, gate: .init(baseBudget: 15))
        let scope = NumericJointQuery.build(frontier: frontier, graph: graph, arity: 3, workLimit: 4096, calculationLimit: 512, scopeLimit: 30)
        #expect(scope.groups.count == 4)
        #expect(scope.groups.first?.leaves.map(\.choice.bitPattern64) == [6, 8, 10])
        #expect(scope.groups.first?.residualVolume == 480)
        #expect(scope.groups.contains { $0.leaves.first?.choice.bitPattern64 == 300 })
        #expect(scope.estimatedWork == scope.groups.reduce(0) { $0 + $1.estimatedWork })
    }

    @Test("Joint proposals preserve mixed signed types")
    func mixedSignedTriple() throws {
        let generator = Gen.zip(Gen.choose(in: Int8(-100) ... -1), Gen.choose(in: UInt64(1) ... 1_000_000), Gen.choose(in: Int16(-10000) ... -1))
        let initial = (Int8(-6), UInt64(8), Int16(-10))
        let tree = try #require(try Interpreters.reflect(generator, with: initial))
        var machine = ReductionMachine(
            gen: generator,
            initialTree: tree,
            initialOutput: initial,
            config: .init(maxStalls: 2, enabledEncoders: [.stagedJointSearch]),
            collectStats: true,
            property: { values in
                let first = Int(values.0)
                let second = Int(values.1)
                let third = Int(values.2)
                return first * first + second * second != third * third
            }
        )
        machine.convergence.deferBindInner = false
        markConverged(&machine.graph)
        let accepted = machine.runStagedJointSearch()
        #expect(accepted)
        let output = try #require(machine.output as? (Int8, UInt64, Int16))
        #expect(output.0 == -3 && output.1 == 4 && output.2 == -5)
        #expect(machine.stats.numericSearchCountsByArity[3]?.accepted == 1)
    }

    @Test("Joint admission checks the final edited leaf's bind identity and rejects clamping")
    func jointAdmission() throws {
        func tree(fingerprint: UInt64) -> ChoiceTree {
            .group([.uint64(6), .uint64(8), .bind(fingerprint: fingerprint, inner: .uint64(10), bound: .uint64(0))])
        }
        let originalTree = tree(fingerprint: 42)
        var graph = ChoiceGraph.build(from: originalTree)
        markConverged(&graph)
        let frontier = NumericJointQuery.frontier(graph: graph, gate: .init(baseBudget: 15))
        let scope = NumericJointQuery.build(frontier: frontier, graph: graph, arity: 3, workLimit: 4096, calculationLimit: 512, scopeLimit: 1)
        let group = try #require(scope.groups.first)
        #expect(group.leaves.map(\.choice.bitPattern64) == [6, 8, 10])
        let admission = DecoderAdmission.numericJoint(group.leaves)
        #expect(admission.admits(tree: originalTree))
        #expect(admission.admits(tree: tree(fingerprint: 43)) == false)
        var candidate = ChoiceSequence(originalTree)
        candidate[group.leaves[0].position] = candidate[group.leaves[0].position].withBitPattern(3)
        candidate[group.leaves[1].position] = candidate[group.leaves[1].position].withBitPattern(4)
        candidate[group.leaves[2].position] = candidate[group.leaves[2].position].withBitPattern(5)
        #expect(admission.admits(decoded: candidate, candidate: candidate, original: ChoiceSequence(originalTree)))
        var clamped = candidate
        clamped[group.leaves[2].position] = clamped[group.leaves[2].position].withBitPattern(4)
        #expect(admission.admits(decoded: clamped, candidate: candidate, original: ChoiceSequence(originalTree)) == false)
    }

    /// Uses actual zip nodes and broad declared domains, with manually settled leaves so direct post-cycle calls exercise the work gate.
    private func machine(values: [Int], tuning: SchedulerTuning = .init(), enabledEncoders: Set<EncoderName> = [.stagedJointSearch], property: @escaping ([Int]) -> Bool) throws -> ReductionMachine {
        let generator = Gen.eachOf(Array(repeating: Gen.choose(in: 1 ... 1_000_000), count: values.count))
        let tree = try #require(try Interpreters.reflect(generator, with: values))
        var machine = ReductionMachine(gen: generator, initialTree: tree, initialOutput: values, config: .init(maxStalls: 2, enabledEncoders: enabledEncoders, tuning: tuning), collectStats: true, property: property)
        machine.convergence.deferBindInner = false
        markConverged(&machine.graph)
        return machine
    }

    private func markConverged(_ graph: inout ChoiceGraph) {
        for nodeID in graph.leafNodes {
            guard case let .chooseBits(metadata) = graph.nodes[nodeID].kind else { continue }
            graph.convergenceStore[nodeID] = ConvergedOrigin(bound: metadata.value.bitPattern64, signal: .monotoneConvergence, configuration: .binarySearchSemanticSimplest, cycle: 0)
        }
    }

    private func unsignedTree(values: [UInt64], range: ClosedRange<UInt64>) -> ChoiceTree {
        .group(values.map { .choice(ChoiceValue($0, tag: .uint64), .init(validRange: range, isRangeExplicit: true)) })
    }

    private func determiningTriples(count: Int) -> [[Int]] {
        (0 ..< count - 2).flatMap { first in
            ((first + 1) ..< count - 1).flatMap { second in
                ((second + 1) ..< count).map { [first, second, $0] }
            }
        }
    }

    private func finish(_ machine: inout ReductionMachine) {
        for _ in 0 ..< 10000 {
            guard machine.next() != nil else { return }
        }
        Issue.record("Joint search did not terminate")
    }
}
