//
//  ReducerStrategies+RedistributeNumericPairs.swift
//  Exhaust
//
//  Created by Chris Kolbu on 17/2/2026.
//

extension ReducerStrategies {
    /// Pass 5b: Cross-container value redistribution.
    /// For each pair of numeric values with the same tag, tries to decrease the earlier value
    /// (toward its reduction target) while increasing the later value by the same amount k.
    /// This enables reduction when values in different containers are coupled.
    ///
    /// - Complexity: O(*s* + *v*² · log *d* · *M*), where *s* is the sequence length,
    ///   *v* is the number of numeric values (bounded to ≤ 16 by the caller), *d* is the maximum
    ///   bit-pattern distance, and *M* is the cost of a single oracle call. Iterates over O(*v*²)
    ///   cross-container pairs, each invoking `findInteger` with O(log *d*) oracle calls.
    static func redistributeNumericPairs<Output>(
        _ gen: ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        property: (Output) -> Bool,
        sequence: ChoiceSequence,
        rejectCache: inout ReducerCache,
    ) throws -> (ChoiceSequence, Output)? {
        // Collect all numeric value/reduced entries with their sequence indices and container IDs.
        // Container ID increments each time we cross a container boundary (group/sequence close),
        // so values in different containers get different IDs.
        typealias Candidate = (index: Int, value: ChoiceSequenceValue.Value, containerID: Int)
        var candidatesByTag = [TypeTag: [Candidate]]()
        var containerID = 0

        for (i, entry) in sequence.enumerated() {
            switch entry {
            case .group(false), .sequence(false):
                containerID += 1
            case let .value(v), let .reduced(v):
                switch v.choice {
                case .unsigned, .signed, .floating:
                    candidatesByTag[v.choice.tag, default: []].append((i, v, containerID))
                case .character:
                    break
                }
            default:
                break
            }
        }

        var current = sequence
        var progress = false
        var latestOutput: Output?

        for (_, candidates) in candidatesByTag {
            guard candidates.count >= 2 else { continue }

            for ci in 0 ..< candidates.count {
                for cj in (ci + 1) ..< candidates.count {
                    // Only pair values in different containers
                    guard candidates[ci].containerID != candidates[cj].containerID else { continue }

                    let (idx1, _, _) = candidates[ci]
                    let (idx2, _, _) = candidates[cj]

                    // Use current values (may have been updated by prior iterations)
                    guard let fresh1 = current[idx1].value,
                          let fresh2 = current[idx2].value else { continue }

                    let bp1 = fresh1.choice.bitPattern64
                    let target1 = fresh1.choice.reductionTarget(in: fresh1.validRanges)
                    guard bp1 != target1 else { continue }

                    let bp2 = fresh2.choice.bitPattern64
                    let target2 = fresh2.choice.reductionTarget(in: fresh2.validRanges)

                    // Determine direction: move bp1 toward target1
                    let decrease1Upward = target1 > bp1
                    let distance1 = decrease1Upward
                        ? target1 - bp1
                        : bp1 - target1

                    // Compute node2's initial distance from its target
                    let distance2 = bp2 > target2 ? bp2 - target2 : target2 - bp2

                    // Skip if node2 is already at its target — no point moving it away.
                    guard distance2 > 0 else { continue }

                    // Only redistribute when node1 is far enough from its target to justify the
                    // disruption to node2. Small distances are better handled by independent reduction.
                    guard distance1 > 16 else { continue }

                    // Only redistribute if node1 is farther from target than node2.
                    // This prevents degenerate swaps where values just trade magnitudes.
                    guard distance1 > distance2 else { continue }

                    var lastProbe: ChoiceSequence?
                    var lastProbeOutput: Output?

                    let bestK = AdaptiveProbe.findInteger { (k: UInt64) -> Bool in
                        guard k > 0 else { return true }
                        guard k <= distance1 else { return false }

                        // Move node1 toward its target by k
                        let newBP1 = decrease1Upward ? bp1 + k : bp1 - k
                        // Move node2 away from its target by k (opposite direction)
                        let newBP2: UInt64
                        if decrease1Upward {
                            // node1 increases by k, so node2 must decrease by k
                            guard bp2 >= k else { return false }
                            newBP2 = bp2 - k
                        } else {
                            // node1 decreases by k, so node2 must increase by k
                            guard UInt64.max - k >= bp2 else { return false }
                            newBP2 = bp2 + k
                        }

                        let newChoice1 = ChoiceValue(
                            fresh1.choice.tag.makeConvertible(bitPattern64: newBP1),
                            tag: fresh1.choice.tag,
                        )
                        let newChoice2 = ChoiceValue(
                            fresh2.choice.tag.makeConvertible(bitPattern64: newBP2),
                            tag: fresh2.choice.tag,
                        )

                        guard newChoice1.fits(in: fresh1.validRanges),
                              newChoice2.fits(in: fresh2.validRanges) else { return false }

                        var probe = current
                        probe[idx1] = .reduced(.init(choice: newChoice1, validRanges: fresh1.validRanges))
                        probe[idx2] = .value(.init(choice: newChoice2, validRanges: fresh2.validRanges))

                        guard probe.shortLexPrecedes(current) else { return false }

                        guard rejectCache.contains(probe) == false else {
                            return false
                        }
                        guard let output = try? Interpreters.materialize(gen, with: tree, using: probe) else {
                            rejectCache.insert(probe)
                            return false
                        }
                        let success = property(output) == false
                        if success {
                            lastProbe = probe
                            lastProbeOutput = output
                        } else {
                            rejectCache.insert(probe)
                        }
                        return success
                    }

                    if bestK > 0, let probe = lastProbe, let output = lastProbeOutput {
                        current = probe
                        latestOutput = output
                        progress = true
                    }
                }
            }
        }

        if progress, let output = latestOutput {
            return (current, output)
        }
        return nil
    }
}
