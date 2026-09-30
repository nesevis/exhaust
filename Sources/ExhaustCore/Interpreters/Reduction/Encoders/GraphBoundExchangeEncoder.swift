//
//  GraphBoundExchangeEncoder.swift
//  Exhaust
//

// MARK: - Graph Bound Exchange Encoder

/// Trades magnitude from a bind inner into a leaf its bind determines, lifting each candidate through the generator.
///
/// The source bind inner walks from its current value towards its target along the midpoints of a ``BinarySearchStepper`` that is never told a probe was accepted, so the steps it gives up run from about half the distance down to one. For each step, the sink is moved the same distance the other way, the candidate carrying both changes is lifted, and the sink is located in the lifted graph. When the lift kept the raised value, the lowered source left room for it and the lifted sequence is emitted. Otherwise nothing is emitted for that step, so a sink the lowered bind inner has capped costs no property evaluation.
///
/// The encoder is stateful: its candidates are lifted sequences whose bound subtrees differ from the dispatched tree, so they are decoded exactly, and an acceptance ends the pass through ``refreshState(graph:sequence:)``.
///
/// The encoder does not know the generator; the scheduler supplies ``lift`` at dispatch time.
struct GraphBoundExchangeEncoder: StatefulGraphEncoder {
    typealias Lift = (_ candidate: ChoiceSequence, _ fallbackTree: ChoiceTree) -> ChoiceTree?

    let name: EncoderName = .boundExchange

    /// Lifts that keep the raised sink, and so produce a probe, per pass. Lifts that drop the raised sink are not counted.
    static let keptLiftBudget = 8

    private let lift: Lift
    private var parentScope: EncoderInput?
    private var exchange: BoundExchangeScope?
    private var sourceIndex = -1
    private var typeTag: TypeTag = .uint
    private var validRange: ClosedRange<UInt64>?
    private var isRangeExplicit = false
    private var stepper: BinarySearchStepper?
    private var needsFirstStep = true

    /// Lifts that kept the raised sink in the current pass. Read by the pass report for diagnostics; deliberately not cleared by ``refreshState(graph:sequence:)`` so accepting passes report their true lift spend.
    private(set) var keptLifts = 0

    init(lift: @escaping Lift) {
        self.lift = lift
    }

    mutating func start(scope: EncoderInput) {
        parentScope = nil
        exchange = nil
        stepper = nil
        needsFirstStep = true
        keptLifts = 0

        guard case let .exchange(.boundExchange(exchange)) = scope.transformation.operation else {
            return
        }
        let graph = scope.graph
        guard exchange.sourceLeafNodeID < graph.nodes.count,
              case let .chooseBits(metadata) = graph.nodes[exchange.sourceLeafNodeID].kind,
              let range = graph.nodes[exchange.sourceLeafNodeID].positionRange,
              range.lowerBound < scope.baseSequence.count,
              scope.baseSequence[range.lowerBound].value != nil
        else {
            return
        }

        let currentBitPattern = metadata.value.bitPattern64
        let targetBitPattern = metadata.value.reductionTarget(in: metadata.validRange)
        guard currentBitPattern != targetBitPattern else {
            return
        }

        parentScope = scope
        self.exchange = exchange
        sourceIndex = range.lowerBound
        typeTag = metadata.typeTag
        validRange = metadata.validRange
        isRangeExplicit = metadata.isRangeExplicit
        if currentBitPattern > targetBitPattern {
            stepper = BinarySearchStepper(lo: targetBitPattern, hi: currentBitPattern, direction: .findSmallest)
        } else {
            stepper = BinarySearchStepper(lo: currentBitPattern, hi: targetBitPattern, direction: .findLargest)
        }
    }

    mutating func nextProbe(into candidate: inout ChoiceSequence, lastAccepted _: Bool) -> EncoderProbe? {
        guard let parent = parentScope, let exchange else {
            return nil
        }

        while keptLifts < Self.keptLiftBudget {
            guard let bitPattern = nextSourceBitPattern() else {
                return nil
            }
            let newChoice = ChoiceValue(
                typeTag.makeConvertible(bitPattern64: bitPattern),
                tag: typeTag
            )
            var sourceCandidate = parent.baseSequence
            sourceCandidate[sourceIndex] = .value(.init(
                choice: newChoice,
                validRange: validRange,
                isRangeExplicit: isRangeExplicit
            ))

            guard let exchanged = exchangedCandidate(
                sourceCandidate: sourceCandidate,
                parent: parent,
                exchange: exchange
            ) else {
                continue
            }
            keptLifts += 1
            candidate = exchanged
            return .leafValues([LeafChange(
                leafNodeID: exchange.sourceLeafNodeID,
                newValue: newChoice,
                mayReshape: true
            )])
        }
        return nil
    }

    /// Ends the pass. The steps were calibrated to the pre-acceptance sequence, and the scheduler re-dispatches against the rebuilt graph.
    mutating func refreshState(graph _: ChoiceGraph, sequence _: ChoiceSequence) {
        parentScope = nil
    }

    // MARK: - Private

    /// The source's next value, walking towards its target by halving steps. The stepper never hears of an acceptance, since an accepted probe ends the pass.
    private mutating func nextSourceBitPattern() -> UInt64? {
        if needsFirstStep {
            needsFirstStep = false
            return stepper?.start()
        }
        return stepper?.advance(lastAccepted: false)
    }

    /// Places the sink's share of the delta in one source candidate and lifts it, or returns nil when the lift fails, the sink cannot be located, or the lift did not keep the raised sink.
    private func exchangedCandidate(
        sourceCandidate: ChoiceSequence,
        parent: EncoderInput,
        exchange: BoundExchangeScope
    ) -> ChoiceSequence? {
        let graph = parent.graph
        guard let sourceIndex = graph.nodes[exchange.sourceLeafNodeID].positionRange?.lowerBound,
              let sinkIndex = graph.nodes[exchange.sinkLeafNodeID].positionRange?.lowerBound,
              sourceIndex < sourceCandidate.count,
              sinkIndex < parent.baseSequence.count,
              let currentSource = parent.baseSequence[sourceIndex].value?.choice.bitPattern64,
              let proposedSource = sourceCandidate[sourceIndex].value?.choice.bitPattern64,
              let currentSink = parent.baseSequence[sinkIndex].value?.choice.bitPattern64,
              proposedSource != currentSource
        else {
            return nil
        }

        // The source moves towards its target; the sink moves the same distance the other way.
        let raisedSink: UInt64
        if proposedSource < currentSource {
            let (sum, overflow) = currentSink.addingReportingOverflow(currentSource - proposedSource)
            guard overflow == false else {
                return nil
            }
            raisedSink = sum
        } else {
            let delta = proposedSource - currentSource
            guard currentSink >= delta else {
                return nil
            }
            raisedSink = currentSink - delta
        }

        // Both changes go into one candidate and one lift. Lowering the source alone first would shrink whatever it sizes, and regrowing it when the sink rises re-resolves the regrown entries, losing their content.
        var exchanged = sourceCandidate
        exchanged[sinkIndex] = exchanged[sinkIndex].withBitPattern(raisedSink)
        guard let freshTree = lift(exchanged, parent.tree) else {
            return nil
        }
        let liftedSequence = ChoiceSequence(freshTree)
        let liftedGraph = ChoiceGraph.build(from: freshTree)
        guard let liftedSinkIndex = Self.locateSink(
            exchange: exchange,
            parentGraph: graph,
            parentSinkIndex: sinkIndex,
            liftedGraph: liftedGraph
        ),
            liftedSinkIndex < liftedSequence.count,
            liftedSequence[liftedSinkIndex].value?.choice.bitPattern64 == raisedSink
        else {
            // The lift re-resolved the sink: the lowered source leaves no room for the raised value.
            return nil
        }
        return liftedSequence
    }

    /// Finds the sink's position in the lifted graph through its bind, matched by fingerprint and path. A sink that is a bind inner is found as its bind's inner child. Any other sink keeps its offset in the bind's fixed-shape bound range, which must not have changed length.
    private static func locateSink(
        exchange: BoundExchangeScope,
        parentGraph: ChoiceGraph,
        parentSinkIndex: Int,
        liftedGraph: ChoiceGraph
    ) -> Int? {
        guard exchange.sinkBindNodeID < parentGraph.nodes.count,
              case let .bind(parentMetadata) = parentGraph.nodes[exchange.sinkBindNodeID].kind,
              let liftedBindNodeID = liftedGraph.liveNodeIDs.first(where: { nodeID in
                  guard case let .bind(metadata) = liftedGraph.nodes[nodeID].kind else {
                      return false
                  }
                  return metadata.fingerprint == parentMetadata.fingerprint
                      && metadata.bindPath == parentMetadata.bindPath
              }),
              case let .bind(liftedMetadata) = liftedGraph.nodes[liftedBindNodeID].kind
        else {
            return nil
        }
        let liftedChildren = liftedGraph.nodes[liftedBindNodeID].children

        if exchange.sinkIsBindInner {
            guard liftedChildren.count > liftedMetadata.innerChildIndex else {
                return nil
            }
            let innerID = liftedChildren[liftedMetadata.innerChildIndex]
            guard case .chooseBits = liftedGraph.nodes[innerID].kind else {
                return nil
            }
            return liftedGraph.nodes[innerID].positionRange?.lowerBound
        }

        let parentChildren = parentGraph.nodes[exchange.sinkBindNodeID].children
        guard parentChildren.count > parentMetadata.boundChildIndex,
              liftedChildren.count > liftedMetadata.boundChildIndex,
              let parentBound = parentGraph.nodes[parentChildren[parentMetadata.boundChildIndex]].positionRange,
              let liftedBound = liftedGraph.nodes[liftedChildren[liftedMetadata.boundChildIndex]].positionRange,
              parentBound.count == liftedBound.count,
              parentBound.contains(parentSinkIndex)
        else {
            return nil
        }
        return liftedBound.lowerBound + (parentSinkIndex - parentBound.lowerBound)
    }
}
