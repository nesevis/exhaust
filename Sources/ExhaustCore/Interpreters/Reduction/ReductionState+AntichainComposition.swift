//
//  ReductionState+AntichainComposition.swift
//  Exhaust
//
//  Created by Chris Kolbu on 25/3/2026.
//

// MARK: - Antichain Candidate Collection

extension ReductionState {
  /// Collects the best deletion candidate for each antichain node by querying the span cache across all slot categories within the node's scope range.
  ///
  /// Returns candidates sorted by `deletedLength` descending so the delta-debugging binary split places high-impact nodes in the first half. Excludes nodes with no deletable spans in any slot category.
  func collectAntichainCandidates(
    antichainNodes: [Int],
    dag: ChoiceDependencyGraph
  ) -> [(nodeIndex: Int, spans: [ChoiceSpan], deletedLength: Int)] {
    var candidates = [(nodeIndex: Int, spans: [ChoiceSpan], deletedLength: Int)]()

    for nodeIndex in antichainNodes {
      guard let scopeRange = dag.nodes[nodeIndex].scopeRange else {
        continue
      }

      var bestSpans = [ChoiceSpan]()
      var bestLength = 0

      for slot in ReductionScheduler.DeletionEncoderSlot.allCases {
        let spans = spanCache.deletionTargets(
          category: slot.spanCategory,
          inRange: scopeRange,
          from: sequence
        )
        guard spans.isEmpty == false else { continue }
        let totalLength = spans.reduce(0) { $0 + $1.range.count }
        if totalLength > bestLength {
          bestSpans = spans
          bestLength = totalLength
        }
      }

      if bestSpans.isEmpty == false {
        candidates.append((
          nodeIndex: nodeIndex,
          spans: bestSpans,
          deletedLength: bestLength
        ))
      }
    }

    candidates.sort { $0.deletedLength > $1.deletedLength }
    return candidates
  }
}
