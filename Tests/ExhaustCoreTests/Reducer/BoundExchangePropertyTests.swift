import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Bound exchange properties")
struct BoundExchangePropertyTests {
    @available(macOS 15.0, *)
    @Test("Every joint proposal preserves the semantic sum and excludes unrepresentable sink deltas")
    func sumPreservationAndOverflow() throws {
        try exhaustCheck(exchangeInputGen, maxIterations: 1000) { input in
            let tree = ChoiceTree.bind(
                fingerprint: 1,
                inner: .choice(input.sourceChoice, .init(validRange: input.range, isRangeExplicit: true)),
                bound: .choice(input.sinkChoice, .init(validRange: nil, isRangeExplicit: false))
            )
            let graph = ChoiceGraph.build(from: tree)
            let sequence = ChoiceSequence(tree)
            let sourceNodeID = try #require(graph.leafNodes.first)
            let sinkNodeID = try #require(graph.leafNodes.last)
            let exchange = BoundExchangeScope(
                sourceLeafNodeID: sourceNodeID,
                sinkLeafNodeID: sinkNodeID,
                sinkLocation: .boundLeaf(bindNodeID: 0)
            )
            let priority = DispatchPriority(
                structuralBenefit: 0,
                valueBenefit: 0,
                reductionMagnitude: 0,
                estimatedCost: 1
            )
            let scope = EncoderInput(
                transformation: GraphTransformation(operation: .exchange(.boundExchange(exchange)), priority: priority),
                baseSequence: sequence,
                tree: tree,
                graph: graph,
                warmStartRecords: [:]
            )
            var cursor = BoundExchangeProposalCursor(scope: scope, exchange: exchange)
            var candidate = sequence
            var actual: [ChoiceValue] = []
            let originalSum = input.semantic(input.sourceChoice) + input.semantic(input.sinkChoice)
            while let proposal = cursor?.next(into: &candidate) {
                let values = proposal.prefix.compactMap(\.value)
                guard values.count == 2 else {
                    return false
                }
                let source = values[0].choice
                let sink = values[1].choice
                guard input.semantic(source) + input.semantic(sink) == originalSum,
                      input.semantic(source) != input.semantic(input.sourceChoice),
                      input.range.contains(source.bitPattern64)
                else {
                    return false
                }
                actual.append(source)
            }

            let candidates = LeafCandidates.rejectedBinarySearch(
                current: input.source,
                target: input.sourceChoice.reductionTarget(in: input.range)
            )
            let expected = candidates.map { input.choice($0) }.filter { source in
                source != input.sourceChoice && input.representableRange.contains(originalSum - input.semantic(source))
            }
            return actual == expected
        }
    }

    @available(macOS 15.0, *)
    @Test("Rejected binary-search proposals match the adaptive encoder's rejection order")
    func rejectedLadderParity() throws {
        try exhaustCheck(exchangeInputGen, maxIterations: 1000) { input in
            let tree = ChoiceTree.choice(input.sourceChoice, .init(validRange: input.range, isRangeExplicit: true))
            let graph = ChoiceGraph.build(from: tree)
            let leafNodeID = try #require(graph.leafNodes.first)
            let scope = EncoderInput(
                transformation: GraphTransformation(
                    operation: .minimize(.valueLeaves(.init(
                        leaves: [.init(nodeID: leafNodeID, mayReshapeOnAcceptance: false)],
                        batchZeroEligible: false
                    ))),
                    priority: DispatchPriority(
                        structuralBenefit: 0,
                        valueBenefit: 0,
                        reductionMagnitude: 0,
                        estimatedCost: 1
                    )
                ),
                baseSequence: ChoiceSequence(tree),
                tree: tree,
                graph: graph,
                warmStartRecords: [:]
            )
            var adaptive = GraphBinarySearchEncoder()
            adaptive.start(scope: scope)
            var candidate = scope.baseSequence
            var actual: [UInt64] = []
            while adaptive.nextProbe(into: &candidate, lastAccepted: false) != nil {
                try actual.append(#require(candidate.first?.value?.choice.bitPattern64))
            }
            return actual == LeafCandidates.rejectedBinarySearch(
                current: input.source,
                target: input.sourceChoice.reductionTarget(in: input.range)
            )
        }
    }
}

/// Uses 128-bit arithmetic for the oracle so even two full-width unsigned values can be added without wrapping.
@available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *)
private struct ExchangeInput {
    let range: ClosedRange<UInt64>
    let source: UInt64
    let sink: UInt64
    let isSigned: Bool

    private var tag: TypeTag {
        isSigned ? .int64 : .uint64
    }

    func choice(_ bitPattern: UInt64) -> ChoiceValue {
        ChoiceValue(tag.makeConvertible(bitPattern64: bitPattern), tag: tag)
    }

    var sourceChoice: ChoiceValue {
        choice(source)
    }

    var sinkChoice: ChoiceValue {
        choice(sink)
    }

    var representableRange: ClosedRange<Int128> {
        isSigned ? Int128(Int64.min) ... Int128(Int64.max) : 0 ... Int128(UInt64.max)
    }

    func semantic(_ choice: ChoiceValue) -> Int128 {
        isSigned ? Int128(choice.decodedSignedValue) : Int128(choice.bitPattern64)
    }
}

/// Exercises narrow and full-width ranges around both representation limits and signed zero. Sink values include both limits independently of the source range.
@available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *)
private let exchangeInputGen: Generator<ExchangeInput> = {
    let boundaryBits = Gen.pick(choices: [
        (1, Gen.choose(in: UInt64(0) ... 100)),
        (1, Gen.choose(in: UInt64.max - 100 ... UInt64.max)),
        (1, Gen.choose(in: UInt64(Int64.max) - 100 ... UInt64(Int64.max) + 100)),
        (1, Gen.choose(in: UInt64.min ... UInt64.max, scaling: .constant)),
    ])
    return Gen.zip(
        boundaryBits,
        Gen.pick(choices: [
            (1, Gen.choose(in: UInt64(0) ... 100)),
            (1, Gen.choose(in: UInt64.min ... UInt64.max, scaling: .constant)),
        ]),
        Gen.choose(in: UInt64.min ... UInt64.max, scaling: .constant),
        boundaryBits,
        Gen.choose(in: UInt64(0) ... 1)
    ).map { lower, width, sourceSeed, sink, signed in
        let span = min(width, UInt64.max - lower)
        let offset = span == UInt64.max ? sourceSeed : sourceSeed % (span + 1)
        return ExchangeInput(
            range: lower ... lower + span,
            source: lower + offset,
            sink: sink,
            isSigned: signed == 1
        )
    }
}()
