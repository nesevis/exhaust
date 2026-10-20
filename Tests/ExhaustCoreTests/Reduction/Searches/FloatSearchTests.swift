import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Float precision search")
struct FloatSearchTests {
    @Test("Rounding neighbors use the leaf's precision", arguments: [TypeTag.double, .float, .float16])
    func neighborsUseLeafPrecision(tag: TypeTag) throws {
        let unit = try #require(tag.floatingChoice(from: 1))
        let candidates = FloatReduction.boundaryCandidates(for: 3.125, tag: tag)

        #expect(candidates.contains(unit.bitPattern64 - 1))
        #expect(candidates.contains(unit.bitPattern64 + 1))
        #expect(Set(candidates).count == candidates.count)
        #expect(candidates.allSatisfy { tag.numericDoubleValue(forBitPattern: $0).isFinite })
    }

    @Test("Fine dyadic boundaries are reached beyond the old truncation limit", arguments: [1.0, -1.0])
    func fineFractionalBoundary(sign: Double) throws {
        let boundary = 3 + 1.0 / 1_048_576
        let initial = sign * (boundary + 1.0 / 16_777_216)
        let generator = Gen.choose(in: -10.0 ... 10.0)
        let output = try reduceFromReflection(
            generator,
            startingAt: initial,
            config: .init(maxStalls: 2, enabledEncoders: [.floatSearch])
        ) { value in
            let magnitude = value * sign
            return (magnitude >= boundary && magnitude < boundary + 1.0 / 4_194_304) == false
        }

        #expect(output == sign * boundary)
    }

    @Test("Subnormal grids do not overflow their reciprocal scale", arguments: [1.0, -1.0])
    func subnormalBoundary(sign: Double) throws {
        let smallest = Double.leastNonzeroMagnitude
        let generator = Gen.choose(in: -3 * smallest ... 3 * smallest)
        let output = try reduceFromReflection(
            generator,
            startingAt: sign * 3 * smallest,
            config: .init(maxStalls: 2, enabledEncoders: [.floatSearch])
        ) { value in
            value * sign <= smallest
        }

        #expect(output == sign * 2 * smallest)
    }

    @Test("A subnormal leaf's grid walk spends probes logarithmic in its depth")
    func subnormalWalkIsLogarithmic() throws {
        let smallest = Double.leastNonzeroMagnitude
        var invocations = 0
        let output = try reduceFromReflection(
            Gen.choose(in: 0.0 ... 1.0),
            startingAt: smallest,
            config: .init(maxStalls: 2, enabledEncoders: [.floatSearch])
        ) { value in
            invocations += 1
            return value != smallest
        }

        #expect(output == smallest)
        // Probing every one of the 1074 coarser grids would spend over a thousand invocations.
        #expect(invocations < 100)
    }

    @Test("Small fractions can simplify to a coarser exponent", arguments: [0.1, Double.leastNonzeroMagnitude])
    func coarserFractionalExponent(initial: Double) throws {
        let generator = Gen.choose(in: 0.0 ... 1.0)
        let output = try reduceFromReflection(
            generator,
            startingAt: initial,
            config: .init(maxStalls: 2, enabledEncoders: [.floatSearch])
        ) { value in
            value <= 0 || value >= 1
        }

        #expect(output == 0.5)
    }

    @Test("Neighbor probes stay inside an explicit range")
    func boundedCancellation() throws {
        let bounds = 1.25 ... 1.75
        let generator = Gen.choose(in: bounds)
        let output = try reduceFromReflection(
            generator,
            startingAt: 1.3,
            config: .init(maxStalls: 2, enabledEncoders: [.floatSearch])
        ) { value in
            #expect(bounds.contains(value))
            return (value + 1) - 1 == value
        }

        #expect(output == 1.5.nextUp)
    }

    @Test("Float cancellation reduces to one ULP from one")
    func singlePrecisionCancellation() throws {
        let leaf = Gen.choose(in: Float(-100) ... 100)
        let generator = Gen.zip(leaf, leaf)
        let initial: (Float, Float) = (1, Float(3).nextUp)
        let property: ((Float, Float)) -> Bool = { values in
            (values.0 + values.1) - values.1 == values.0
        }
        #expect(property(initial) == false)

        let output = try reduceFromReflection(
            generator,
            startingAt: initial,
            config: .init(maxStalls: 2, enabledEncoders: [.floatSearch]),
            property: property
        )

        #expect(output.0 == 1)
        #expect(output.1 == Float(1).nextUp)
        #expect(property(output) == false)
    }

    @Test("Accepting a batch probe prepares the next leaf's own target")
    func acceptancePreparesNextLeaf() throws {
        let generator = Gen.zip(Gen.choose(in: 0.0 ... 10.0), Gen.choose(in: 2.0 ... 10.0))
        let tree = try #require(try Interpreters.reflect(generator, with: (3.5, 4.5)))
        let graph = ChoiceGraph.build(from: tree)
        let sequence = ChoiceSequence(tree)
        let leaves = graph.leafNodes.sorted {
            graph.nodes[$0].positionRange!.lowerBound < graph.nodes[$1].positionRange!.lowerBound
        }
        let positions = leaves.map { graph.nodes[$0].positionRange!.lowerBound }
        var search = FloatSearch(
            scope: FloatMinimizationScope(leaves: leaves.map { LeafEntry(nodeID: $0) }),
            sequence: sequence,
            graph: graph
        )
        var buffer = sequence
        _ = try #require(search.next(.initial, into: &buffer))
        #expect(buffer[positions[0]].value?.choice.decodedDoubleValue == 0)

        _ = try #require(search.next(.accepted(recovered: buffer), into: &buffer))
        #expect(buffer[positions[0]].value?.choice.decodedDoubleValue == 0)
        #expect(buffer[positions[1]].value?.choice.decodedDoubleValue == 2)
    }
}
