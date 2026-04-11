//
//  BranchProjectionPass.swift
//  Exhaust
//
//  Created by Chris Kolbu on 30/3/2026.
//

// MARK: - Phase 0: Branch Projection

//
// Runs before the value projection pass and the main reduction cycle.
// For each pick site in the choice tree, identifies the shortlex-simplest
// branch alternative and tries selecting it. All simplifications are applied
// in a single batch probe. If the batch fails, falls back to binary search
// over subsets of sites to find the largest viable batch.
//
// This is the branch-level analog of FreeCoordinateProjectionPass: where that
// pass zeros independent values, this pass simplifies branch selections. Together
// they form a complete "try the dumbest thing first" pre-pass that handles both
// axes before the main cycle begins.

/// Selects the shortlex-simplest branch alternative at every pick site before the main reduction loop.
///
/// For each pick site, computes which alternative has the smallest flattened complexity and builds a candidate that selects it. Applies all site simplifications in a single probe. If the batch is rejected, binary-searches for the largest subset that preserves the failure.
public struct BranchProjectionPass: ReductionPass {
    public let name: EncoderName = .branchProjection

    /// Projects all branch selections to their shortlex-simplest alternative.
    ///
    /// Returns the projected result if the property still fails with simplified branches, or `nil` if no simplification is possible.
    public func encode<Output>(
        gen: ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        sequence: ChoiceSequence,
        property: @escaping (Output) -> Bool,
        isInstrumented: Bool
    ) -> (result: ReductionPassResult<Output>, probes: Int)? {
        // Collect per-site diffs: for each pick site, compute a single-site
        // candidate that selects the simplest alternative. We work at the
        // choice sequence level to avoid fingerprint invalidation.
        let branchGroups = extractBranchGroups(from: tree)
        guard branchGroups.isEmpty == false else {
            log(isInstrumented, sites: 0, accepted: false, probes: 0)
            return nil
        }

        var siteDiffs: [(site: Fingerprint, candidate: ChoiceSequence)] = []

        for site in branchGroups {
            guard case let .group(elements, _) = tree[site] else { continue }

            // Find the shortlex-simplest alternative among all branches.
            var bestIndex: Int?
            var bestComplexity: ChoiceSequence?
            for index in 0 ..< elements.count {
                guard elements[index].unwrapped.isBranch else { continue }
                let complexity = ChoiceSequence.flatten(
                    elements[index],
                    includingAllBranches: true
                )
                if bestComplexity == nil || complexity.shortLexPrecedes(bestComplexity!) {
                    bestIndex = index
                    bestComplexity = complexity
                }
            }
            guard let simplestIndex = bestIndex else { continue }

            // Build a single-site candidate selecting the simplest branch.
            // Deselect any currently selected branch and select the simplest.
            var candidateElements = elements
            for index in 0 ..< candidateElements.count {
                if candidateElements[index].isSelected {
                    candidateElements[index] = candidateElements[index].unwrapped
                }
            }
            candidateElements[simplestIndex] = .selected(elements[simplestIndex].unwrapped)

            var candidateTree = tree
            candidateTree[site] = .group(candidateElements)
            let candidateSequence = ChoiceSequence.flatten(candidateTree)

            // Only include sites where the candidate is strictly shortlex-smaller.
            // With branch-transparent shortlex, different branch selections can produce
            // identical flattened sequences — the != check alone would loop.
            if candidateSequence.shortLexPrecedes(sequence) {
                siteDiffs.append((site, candidateSequence))
            }
        }

        guard siteDiffs.isEmpty == false else {
            log(isInstrumented, sites: 0, accepted: false, probes: 0)
            return nil
        }

        // Try the full batch first: merge all single-site diffs into one candidate.
        let batchCandidate = mergeDiffs(base: sequence, diffs: siteDiffs.map(\.candidate))
        var probes = 0

        if let batchResult = Self.decode(
            candidate: batchCandidate,
            gen: gen,
            fallbackTree: nil,
            property: property
        ) {
            probes += 1
            log(isInstrumented, sites: siteDiffs.count, accepted: true, probes: probes)
            return (batchResult, probes)
        }
        probes += 1

        // Full batch failed. Binary search for the largest prefix of sites that works.
        // Sites are already in tree-walk order (outer to inner), so prefixes prefer
        // higher-level simplifications.
        guard siteDiffs.count >= 2 else {
            log(isInstrumented, sites: siteDiffs.count, accepted: false, probes: probes)
            return nil
        }

        var lo = 0
        var hi = siteDiffs.count
        var bestResult: ReductionPassResult<Output>?

        while lo < hi {
            let mid = lo + (hi - lo) / 2
            guard mid > 0 else { break }
            let partialCandidate = mergeDiffs(
                base: sequence,
                diffs: Array(siteDiffs[0 ..< mid].map(\.candidate))
            )
            if let result = Self.decode(
                candidate: partialCandidate,
                gen: gen,
                fallbackTree: nil,
                property: property
            ) {
                bestResult = result
                lo = mid + 1
                probes += 1
            } else {
                hi = mid
                probes += 1
            }
        }

        if let bestResult {
            log(isInstrumented, sites: lo - 1, accepted: true, probes: probes)
            return (bestResult, probes)
        }

        log(isInstrumented, sites: siteDiffs.count, accepted: false, probes: probes)
        return nil
    }

    // MARK: - Helpers

    /// Merges positional diffs from multiple single-site candidates into one batch candidate.
    ///
    /// Each diff candidate differs from the base at the positions affected by its site's
    /// branch change. Since sites are independent (non-overlapping), their diffs don't conflict.
    private func mergeDiffs(base: ChoiceSequence, diffs: [ChoiceSequence]) -> ChoiceSequence {
        var result = base
        for diff in diffs {
            guard diff.count == base.count else { continue }
            for position in 0 ..< base.count {
                if diff[position] != base[position] {
                    result[position] = diff[position]
                }
            }
        }
        return result
    }

    private func log(_ isInstrumented: Bool, sites: Int, accepted: Bool, probes: Int) {
        guard isInstrumented else { return }
        ExhaustLog.debug(
            category: .reducer,
            event: "phase0_branch_projection",
            metadata: [
                "sites": "\(sites)",
                "accepted": "\(accepted)",
                "probes": "\(probes)",
            ]
        )
    }
}

// MARK: - Branch Group Extraction

/// Finds all branch groups in the tree — groups containing at least two children
/// where at least one is a branch. Unlike the in-cycle pick site extraction, this
/// does not require a `.selected` marker, so it works on reflected trees.
private func extractBranchGroups(from tree: ChoiceTree) -> [Fingerprint] {
    var results: [Fingerprint] = []
    for element in tree.walk() {
        if case let .group(array, _) = element.node,
           array.contains(where: \.unwrapped.isBranch),
           array.count >= 2
        {
            results.append(element.fingerprint)
        }
    }
    return results
}
