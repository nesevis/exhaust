extension GraphRedistributionEncoder {
    /// Keeps the query's leaf identities alongside the arithmetic context for the bounded working set.
    struct PreparedPair {
        let scopePair: RedistributionPair
        let sourceIndex: Int
        let sinkIndex: Int
        let sourceTag: TypeTag
        let sinkTag: TypeTag
        let maxDelta: UInt64
        let mixedContext: MixedRedistributionContext?
    }

    /// Uses the same full-delta preference as materialized candidates, with invalid transfers ranked by distance last.
    struct RankedPair {
        let pair: PreparedPair
        let edit: RedistributionEdit?

        func precedes(_ other: Self, sequence: ChoiceSequence) -> Bool {
            switch (edit, other.edit) {
                case let (.some(edit), .some(otherEdit)):
                    edit.shortLexPrecedes(otherEdit, sequence: sequence)
                case (.some, .none):
                    true
                case (.none, .some):
                    false
                case (.none, .none):
                    pair.maxDelta > other.pair.maxDelta
            }
        }
    }

    /// Represents two value replacements against a common baseline without retaining a candidate sequence.
    ///
    /// Both positions must address value entries. Length and structural ranks stay unchanged, so the first differing edited value decides shortlex. Sink replacement wins if positions coincide, matching candidate construction's write order.
    struct RedistributionEdit {
        let sourceIndex: Int
        let sinkIndex: Int
        let sourceEntry: ChoiceSequenceValue
        let sinkEntry: ChoiceSequenceValue

        func applying(to sequence: ChoiceSequence) -> ChoiceSequence {
            var candidate = sequence
            candidate[sourceIndex] = sourceEntry
            candidate[sinkIndex] = sinkEntry
            return candidate
        }

        /// Compares only the union of edited positions; all other value-projection entries are identical.
        func shortLexPrecedes(_ other: Self, sequence: ChoiceSequence) -> Bool {
            let positions = [sourceIndex, sinkIndex, other.sourceIndex, other.sinkIndex].sorted()
            for position in positions {
                guard let value = entry(at: position, sequence: sequence).value,
                      let otherValue = other.entry(at: position, sequence: sequence).value
                else {
                    preconditionFailure("Redistribution edits must preserve value entries")
                }
                switch value.shortLexCompare(otherValue) {
                    case .lt:
                        return true
                    case .gt:
                        return false
                    case .eq:
                        continue
                }
            }
            return false
        }

        private func entry(at position: Int, sequence: ChoiceSequence) -> ChoiceSequenceValue {
            switch position {
                case sinkIndex:
                    sinkEntry
                case sourceIndex:
                    sourceEntry
                default:
                    sequence[position]
            }
        }
    }

    /// Rejects inactive, character, and target-converged sources before they occupy the bounded ranking set.
    func preparePair(_ pair: RedistributionPair, graph: ChoiceGraph) -> PreparedPair? {
        guard let sourceRange = graph.nodes[pair.source.nodeID].positionRange,
              let sinkRange = graph.nodes[pair.sink.nodeID].positionRange,
              case let .chooseBits(sourceMetadata) = graph.nodes[pair.source.nodeID].kind,
              case let .chooseBits(sinkMetadata) = graph.nodes[pair.sink.nodeID].kind,
              sourceMetadata.typeTag.isCharacter == false,
              sinkMetadata.typeTag.isCharacter == false
        else {
            return nil
        }
        let needsMixedMath = sourceMetadata.typeTag != sinkMetadata.typeTag
            || sourceMetadata.typeTag.isFloatingPoint
            || sinkMetadata.typeTag.isFloatingPoint
        let context: MixedRedistributionContext?
        let maxDelta: UInt64
        switch needsMixedMath {
            case true:
                guard let mixedContext = Self.makeMixedRedistributionContext(
                    sourceChoice: sourceMetadata.value,
                    sinkChoice: sinkMetadata.value,
                    sourceValidRange: sourceMetadata.validRange,
                    sourceIsRangeExplicit: sourceMetadata.isRangeExplicit
                ) else {
                    return nil
                }
                context = mixedContext
                maxDelta = mixedContext.distanceInSteps
            case false:
                let sourceTarget = sourceMetadata.value.reductionTarget(in: sourceMetadata.validRange)
                maxDelta = sourceMetadata.value.bitPattern64 > sourceTarget
                    ? sourceMetadata.value.bitPattern64 - sourceTarget
                    : sourceTarget - sourceMetadata.value.bitPattern64
                guard maxDelta > 0 else {
                    return nil
                }
                context = nil
        }
        return PreparedPair(
            scopePair: pair,
            sourceIndex: sourceRange.lowerBound,
            sinkIndex: sinkRange.lowerBound,
            sourceTag: sourceMetadata.typeTag,
            sinkTag: sinkMetadata.typeTag,
            maxDelta: maxDelta,
            mixedContext: context
        )
    }
}
