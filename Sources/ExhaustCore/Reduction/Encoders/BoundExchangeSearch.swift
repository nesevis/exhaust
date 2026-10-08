/// Constructs sum-preserving exchange proposals and validates their lifted sinks. The composition engine owns lifting, proposal iteration, stage scheduling, and mutation wrapping.
///
/// A kept lift emits its sequence once and is decoded exactly. Acceptance refreshes the engine to idle; attempted and kept lift counters survive so the pass reports all spent work.
enum BoundExchangeSearch {
    /// Limits lifts that preserve the proposal's expected sink value, not all materialization attempts.
    static let keptExchangeLiftBudget = 8

    /// Uses the stage budget for kept lifts: every validated sink constructs one nonempty stage, and failed lifts construct none.
    static func makeEncoder(lift: @escaping GraphComposedEncoder.Lift) -> GraphComposedEncoder {
        GraphComposedEncoder(
            name: .boundExchange,
            makeProposals: { scope in
                guard case let .exchange(.boundExchange(exchange)) = scope.transformation.operation,
                      let cursor = BoundExchangeProposalCursor(scope: scope, exchange: exchange)
                else {
                    return nil
                }
                return (
                    source: .exchange(cursor),
                    downstreamFactory: { proposal, lifted, parent in
                        buildDownstream(
                            proposal: proposal,
                            lifted: lifted,
                            parent: parent,
                            exchange: exchange
                        )
                    }
                )
            },
            policy: CompositionPolicy(stageBudget: keptExchangeLiftBudget, liftSite: .boundExchangeLift),
            lift: lift
        )
    }

    /// Reads the expected sink from the joint proposal, before locating its possibly shifted position in the lifted graph. A kept lift constructs exactly one nonempty stage.
    static func buildDownstream(
        proposal: LiftProposal,
        lifted: LiftResult,
        parent: EncoderInput,
        exchange: BoundExchangeScope
    ) -> DownstreamBuild {
        guard let parentSinkIndex = parent.graph.nodes[exchange.sinkLeafNodeID].positionRange?.lowerBound,
              parentSinkIndex < proposal.prefix.count
        else {
            return .failed(.bindNotFound)
        }
        guard let expected = proposal.prefix[parentSinkIndex].value?.choice.bitPattern64 else {
            return .failed(.sinkValueMismatch)
        }
        let graph = ChoiceGraph.build(from: lifted.tree)
        guard let sinkIndex = locateSink(
            exchange: exchange,
            parentGraph: parent.graph,
            parentSinkIndex: parentSinkIndex,
            liftedGraph: graph
        ),
            sinkIndex < lifted.sequence.count
        else {
            return .failed(.bindNotFound)
        }
        guard lifted.sequence[sinkIndex].value?.choice.bitPattern64 == expected else {
            return .failed(.sinkValueMismatch)
        }
        return .stage(
            encoder: .liftedStage(GraphLiftedStageEncoder(name: .boundExchange, mutation: proposal.mutation)),
            scope: EncoderInput(
                transformation: parent.transformation,
                baseSequence: lifted.sequence,
                tree: lifted.tree,
                graph: graph,
                warmStartRecords: [:]
            )
        )
    }

    /// Locates a bind-inner sink through its bind's inner child, or a bound-leaf sink by its offset in a fixed-length bound range. Fingerprint and path together distinguish repeated bind sites after positions shift.
    private static func locateSink(
        exchange: BoundExchangeScope,
        parentGraph: ChoiceGraph,
        parentSinkIndex: Int,
        liftedGraph: ChoiceGraph
    ) -> Int? {
        let sinkBindNodeID = switch exchange.sinkLocation {
            case let .bindInner(bindNodeID), let .boundLeaf(bindNodeID):
                bindNodeID
        }
        guard parentGraph.nodes.indices.contains(sinkBindNodeID),
              case let .bind(parentMetadata) = parentGraph.nodes[sinkBindNodeID].kind,
              let liftedBindNodeID = liftedGraph.bindNodeID(
                  fingerprint: parentMetadata.fingerprint,
                  path: parentMetadata.bindPath
              ),
              case let .bind(liftedMetadata) = liftedGraph.nodes[liftedBindNodeID].kind
        else {
            return nil
        }
        let liftedChildren = liftedGraph.nodes[liftedBindNodeID].children

        switch exchange.sinkLocation {
            case .bindInner:
                guard liftedChildren.count > liftedMetadata.innerChildIndex else {
                    return nil
                }
                let innerID = liftedChildren[liftedMetadata.innerChildIndex]
                guard case .chooseBits = liftedGraph.nodes[innerID].kind else {
                    return nil
                }
                return liftedGraph.nodes[innerID].positionRange?.lowerBound
            case .boundLeaf:
                let parentChildren = parentGraph.nodes[sinkBindNodeID].children
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
}
