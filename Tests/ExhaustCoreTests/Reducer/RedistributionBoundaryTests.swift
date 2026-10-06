import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Redistribution arithmetic boundaries")
struct RedistributionBoundaryTests {
    @Test("Signed minimum contexts retain the full unsigned distance", arguments: [TypeTag.int, .int32, .uint64, .double, .float])
    func signedMinimumDistance(sinkTag: TypeTag) throws {
        let source = ChoiceValue(Int64.min, tag: .int64)
        let sink = ChoiceValue(sinkTag.simplestBitPattern, tag: sinkTag)
        let context = try #require(makeContext(source: source, sink: sink))
        #expect(context.sourceNumerator == Int64.min)
        #expect(context.sinkNumerator == 0)
        #expect(context.denominator == 1)
        #expect(context.intStepSize == 1)
        #expect(context.sourceMovesUpward)
        #expect(context.distanceInSteps == UInt64(Int64.max) + 1)
    }

    @Test("Full signed-minimum transfers conserve representable totals", arguments: [Int64(0), Int64.max])
    func signedMinimumFullTransfer(sinkValue: Int64) throws {
        let source = ChoiceValue(Int64.min, tag: .int64)
        let sink = ChoiceValue(sinkValue, tag: .int)
        let context = try #require(makeContext(source: source, sink: sink))
        let result = try #require(transfer(source: source, sink: sink, delta: context.distanceInSteps, context: context))
        #expect(result.0.decodedSignedValue == 0)
        #expect(result.1.decodedSignedValue == Int64.min + sinkValue)
        #expect(result.0.decodedSignedValue + result.1.decodedSignedValue == Int64.min + sinkValue)
        #expect(result.0.tag == source.tag)
        #expect(result.1.tag == sink.tag)
    }

    @Test("Mixed floating sinks accept exactly representable large transfers", arguments: [TypeTag.double, .float])
    func signedMinimumFloatingTransfer(sinkTag: TypeTag) throws {
        let source = ChoiceValue(Int64.min, tag: .int64)
        let sink = ChoiceValue(sinkTag.simplestBitPattern, tag: sinkTag)
        let context = try #require(makeContext(source: source, sink: sink))
        let result = try #require(transfer(source: source, sink: sink, delta: context.distanceInSteps, context: context))
        #expect(result.0.decodedSignedValue == 0)
        #expect(result.1.decodedDoubleValue == Double(Int64.min))
        #expect(result.1.tag == sinkTag)
    }

    @Test("Transfers spanning the entire signed range preserve both endpoints", arguments: [true, false])
    func fullSignedSpan(sourceMovesUpward: Bool) throws {
        let sourceValue = sourceMovesUpward ? Int64.min : Int64.max
        let sinkValue = sourceMovesUpward ? Int64.max : Int64.min
        let source = ChoiceValue(sourceValue, tag: .int64)
        let sink = ChoiceValue(sinkValue, tag: .int)
        let context = GraphRedistributionEncoder.MixedRedistributionContext(
            sourceNumerator: sourceValue,
            sinkNumerator: sinkValue,
            denominator: 1,
            intStepSize: 1,
            sourceMovesUpward: sourceMovesUpward,
            distanceInSteps: UInt64.max
        )
        let result = try #require(transfer(source: source, sink: sink, delta: UInt64.max, context: context))
        #expect(result.0.decodedSignedValue == sinkValue)
        #expect(result.1.decodedSignedValue == sourceValue)
        #expect(result.0.decodedSignedValue + result.1.decodedSignedValue == -1)
    }

    @Test("Narrow signed sources reach zero with their own sign encoding", arguments: [TypeTag.int8, .int16, .int32])
    func narrowSignedSource(signedTag: TypeTag) throws {
        let source = ChoiceValue(UInt64(0), tag: signedTag)
        let sink = ChoiceValue(Int64(0), tag: .int64)
        let context = try #require(makeContext(source: source, sink: sink))
        #expect(context.distanceInSteps == source.decodedSignedValue.magnitude)
        let result = try #require(transfer(source: source, sink: sink, delta: context.distanceInSteps, context: context))
        #expect(result.0.decodedSignedValue == 0)
        #expect(result.0.bitPattern64 == signedTag.simplestBitPattern)
        #expect(result.1.decodedSignedValue == source.decodedSignedValue)
        #expect(result.0.tag == signedTag)
    }

    @Test("Narrow signed sinks accept their endpoints and reject one unit beyond", arguments: [TypeTag.int8, .int16, .int32])
    func narrowSignedSink(signedTag: TypeTag) throws {
        let sink = ChoiceValue(signedTag.simplestBitPattern, tag: signedTag)
        let negativeLimit = signedTag.simplestBitPattern
        let positiveLimit = negativeLimit - 1
        let negativeSource = ChoiceValue(Int64.min, tag: .int64)
        let negativeContext = try #require(makeContext(source: negativeSource, sink: sink))
        let negativeResult = try #require(transfer(source: negativeSource, sink: sink, delta: negativeLimit, context: negativeContext))
        #expect(negativeResult.0.decodedSignedValue == Int64.min + Int64(negativeLimit))
        #expect(negativeResult.1.decodedSignedValue == -Int64(negativeLimit))
        #expect(negativeResult.0.decodedSignedValue + negativeResult.1.decodedSignedValue == Int64.min)
        #expect(transfer(source: negativeSource, sink: sink, delta: negativeLimit + 1, context: negativeContext) == nil)

        let positiveSource = ChoiceValue(Int64.max, tag: .int64)
        let positiveContext = try #require(makeContext(source: positiveSource, sink: sink))
        let positiveResult = try #require(transfer(source: positiveSource, sink: sink, delta: positiveLimit, context: positiveContext))
        #expect(positiveResult.0.decodedSignedValue == Int64.max - Int64(positiveLimit))
        #expect(positiveResult.1.decodedSignedValue == Int64(positiveLimit))
        #expect(positiveResult.0.decodedSignedValue + positiveResult.1.decodedSignedValue == Int64.max)
        #expect(transfer(source: positiveSource, sink: sink, delta: positiveLimit + 1, context: positiveContext) == nil)
    }

    @Test("Unsigned sinks enforce their natural width and reject negative results", arguments: [TypeTag.uint8, .uint16, .uint32])
    func narrowUnsignedSink(unsignedTag: TypeTag) throws {
        let source = ChoiceValue(Int64.max, tag: .int64)
        let sink = ChoiceValue(UInt64(0), tag: unsignedTag)
        let maximum = unsignedTag.bitPatternRange.upperBound
        let context = try #require(makeContext(source: source, sink: sink))
        let result = try #require(transfer(source: source, sink: sink, delta: maximum, context: context))
        #expect(result.0.decodedSignedValue == Int64.max - Int64(maximum))
        #expect(result.1.bitPattern64 == maximum)
        #expect(result.1.tag == unsignedTag)
        #expect(transfer(source: source, sink: sink, delta: maximum + 1, context: context) == nil)

        let negativeSource = ChoiceValue(Int64(-1), tag: .int64)
        let negativeContext = try #require(makeContext(source: negativeSource, sink: sink))
        #expect(transfer(source: negativeSource, sink: sink, delta: 1, context: negativeContext) == nil)
    }

    @Test("Signed numerator overflow is rejected while smaller transfers remain valid")
    func signedNumeratorOverflow() throws {
        let source = ChoiceValue(Int64.min, tag: .int64)
        let sink = ChoiceValue(Int64(-1), tag: .int)
        let context = try #require(makeContext(source: source, sink: sink))
        let partial = try #require(transfer(source: source, sink: sink, delta: 1, context: context))
        #expect(partial.0.decodedSignedValue == Int64.min + 1)
        #expect(partial.1.decodedSignedValue == -2)
        #expect(transfer(source: source, sink: sink, delta: context.distanceInSteps, context: context) == nil)

        let positiveSource = ChoiceValue(Int64.max, tag: .int64)
        let positiveSink = ChoiceValue(Int64.max, tag: .int)
        let positiveContext = try #require(makeContext(source: positiveSource, sink: positiveSink))
        #expect(transfer(source: positiveSource, sink: positiveSink, delta: 1, context: positiveContext) == nil)
    }

    @Test("Unrepresentable scaled transfers and integer denominators return nil")
    func scaledArithmeticRejectsOverflow() {
        let source = ChoiceValue(Int64.min, tag: .int64)
        let sink = ChoiceValue(Int64.max, tag: .int)
        let oversizedDelta = GraphRedistributionEncoder.MixedRedistributionContext(
            sourceNumerator: Int64.min,
            sinkNumerator: Int64.max,
            denominator: 2,
            intStepSize: 2,
            sourceMovesUpward: true,
            distanceInSteps: UInt64.max
        )
        #expect(transfer(source: source, sink: sink, delta: UInt64(Int64.max) + 1, context: oversizedDelta) == nil)
        let oversizedDenominator = GraphRedistributionEncoder.MixedRedistributionContext(
            sourceNumerator: Int64.min,
            sinkNumerator: Int64.max,
            denominator: UInt64(Int64.max) + 1,
            intStepSize: 1,
            sourceMovesUpward: true,
            distanceInSteps: UInt64.max
        )
        #expect(transfer(source: source, sink: sink, delta: 1, context: oversizedDenominator) == nil)
        #expect(makeContext(source: source, sink: ChoiceValue(0.5, tag: .double)) == nil)
    }

    @Test("The encoder probes signed minima and stops after an accepted full or capacity-limited transfer", arguments: [TypeTag.int, .int32, .double])
    func encoderHandlesSignedMinimum(sinkTag: TypeTag) throws {
        let sourceChoice = ChoiceValue(Int64.min, tag: .int64)
        let sinkChoice = ChoiceValue(sinkTag.simplestBitPattern, tag: sinkTag)
        let tree = ChoiceTree.group([sourceChoice, sinkChoice].map { choice in
            .choice(choice, .init(validRange: nil, isRangeExplicit: false))
        })
        let fixture = GraphFixture(tree)
        #expect(fixture.graph.leafNodes.count == 2)
        let sourceNodeID = fixture.graph.leafNodes[0]
        let sinkNodeID = fixture.graph.leafNodes[1]
        let sourceIndex = try #require(fixture.graph.nodes[sourceNodeID].positionRange?.lowerBound)
        let sinkIndex = try #require(fixture.graph.nodes[sinkNodeID].positionRange?.lowerBound)
        let pair = RedistributionPair(source: .init(nodeID: sourceNodeID), sink: .init(nodeID: sinkNodeID), sourceTag: .int64, sinkTag: sinkTag)
        var encoder = GraphRedistributionEncoder()
        encoder.valueState.reset(sequence: fixture.sequence)
        encoder.startRedistribution(pairs: [pair], graph: fixture.graph)
        var candidate = fixture.sequence
        let firstProbe = encoder.nextProbe(into: &candidate, lastAccepted: false)
        #expect(firstProbe != nil)
        let newSource = try #require(candidate[sourceIndex].value?.choice)
        let newSink = try #require(candidate[sinkIndex].value?.choice)
        switch sinkTag {
            case .int32:
                #expect(newSource.decodedSignedValue == Int64.min + Int64(Int32.max) + 1)
                #expect(newSink.decodedSignedValue == Int64(Int32.min))
                #expect(newSource.decodedSignedValue + newSink.decodedSignedValue == Int64.min)
            case .double:
                #expect(newSource.decodedSignedValue == 0)
                #expect(newSink.decodedDoubleValue == Double(Int64.min))
            default:
                #expect(newSource.decodedSignedValue == 0)
                #expect(newSink.decodedSignedValue == Int64.min)
        }
        let nextProbe = encoder.nextProbe(into: &candidate, lastAccepted: true)
        #expect(nextProbe == nil)
    }
}

private func makeContext(source: ChoiceValue, sink: ChoiceValue) -> GraphRedistributionEncoder.MixedRedistributionContext? {
    GraphRedistributionEncoder.makeMixedRedistributionContext(
        sourceChoice: source,
        sinkChoice: sink,
        sourceValidRange: nil,
        sourceIsRangeExplicit: false
    )
}

private func transfer(
    source: ChoiceValue,
    sink: ChoiceValue,
    delta: UInt64,
    context: GraphRedistributionEncoder.MixedRedistributionContext
) -> (ChoiceValue, ChoiceValue)? {
    GraphRedistributionEncoder.mixedRedistributedPairChoices(sourceChoice: source, sinkChoice: sink, delta: delta, context: context)
}
