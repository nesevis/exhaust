//
//  ReducerStrategies+ReduceValuesInTandem.swift
//  Exhaust
//
//  Created by Chris Kolbu on 17/2/2026.
//

extension ReducerStrategies {
    /// Pass 7: Binary search multiple values toward their reduction target.
    /// For each sibling group of values will test how much it can reduce all siblings by the same amount.
    ///
    /// - Complexity: O(*g* · log *d* · *M*), where *g* is the number of sibling groups, *d* is the
    ///   maximum bit-pattern distance between a value and its reduction target, and *M* is the cost
    ///   of a single oracle call. Each group invokes `binarySearchWithGuess` with O(log *d*) oracle
    ///   calls; each call adjusts O(*r*) values in the group, dominated by *M*.
    static func reduceValuesInTandem<Output>(
        _ gen: ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        property: (Output) -> Bool,
        sequence: ChoiceSequence,
        siblingGroups: [SiblingGroup],
        rejectCache: inout ReducerCache
    ) throws -> (ChoiceSequence, Output)? {
        var current = sequence
        var progress = false
        var latestOutput: Output?

        for group in siblingGroups {
            // Since all values will be reduced in tandem, grab the distance from semantic zero
            // from the first of the values in this sibling span
            guard
                let firstValueIndex = group.valueRanges?.first?.lowerBound,
                case let v = current[firstValueIndex].value, let v
            else {
                continue
            }
            let currentBP = v.choice.bitPattern64
            let targetBP = v.choice.reductionTarget(in: v.validRanges)

            guard currentBP != targetBP else { continue }

            let searchUpward = targetBP > currentBP
            let distance = searchUpward
                ? targetBP - currentBP
                : currentBP - targetBP

            guard distance > 1 else { continue }

            var lastProbe: ChoiceSequence?
            var lastProbeOutput: Output?
            var lastProbeDelta: UInt64 = 0
            let bestDelta = AdaptiveProbe.binarySearchWithGuess(
                { (delta: UInt64) -> Bool in
                    guard delta > 0 else { return true } // predicate(0) assumed true
                    var probe = current
                    for tandemCandidate in group.valueRanges ?? [] {
                        guard let v = current[tandemCandidate.lowerBound].value else {
                            return true
                        }
                        let newValue = searchUpward
                            ? v.choice.bitPattern64 &+ delta
                            : v.choice.bitPattern64 &- delta
                        let newChoice = ChoiceValue(
                            v.choice.tag.makeConvertible(bitPattern64: newValue),
                            tag: v.choice.tag
                        )
                        guard newChoice.fits(in: v.validRanges) else { continue }
                        probe[tandemCandidate.lowerBound] = .value(.init(choice: newChoice, validRanges: v.validRanges))
                    }

                    guard
                        probe.shortLexPrecedes(current),
                        rejectCache.contains(probe) == false
                    else {
                        return false
                    }
                    guard let output = try? Interpreters.materialize(gen, with: tree, using: probe) else {
                        rejectCache.insert(probe)
                        return false
                    }
                    let success = property(output) == false
                    if success {
                        if delta >= lastProbeDelta {
                            lastProbeDelta = delta
                            lastProbeOutput = output
                            lastProbe = probe
                        }
                    } else {
                        rejectCache.insert(probe)
                    }
                    return success
                },
                low: UInt64(0),
                high: distance
            )

            if bestDelta > 0,
               lastProbeDelta == bestDelta,
               let lastProbeOutput,
               let lastProbe,
               lastProbe.shortLexPrecedes(current)
            {
                latestOutput = lastProbeOutput
                current = lastProbe
                progress = true
                continue
            }

            if bestDelta > 0 {
                // Fallback: reconstruct accepted candidate if probe bookkeeping missed it.
                var probe = current
                for tandemCandidate in group.valueRanges ?? [] {
                    guard let v = current[tandemCandidate.lowerBound].value else { continue }
                    let newValue = searchUpward
                        ? v.choice.bitPattern64 &+ bestDelta
                        : v.choice.bitPattern64 &- bestDelta
                    let newChoice = ChoiceValue(
                        v.choice.tag.makeConvertible(bitPattern64: newValue),
                        tag: v.choice.tag
                    )
                    guard newChoice.fits(in: v.validRanges) else { continue }
                    probe[tandemCandidate.lowerBound] = .value(.init(choice: newChoice, validRanges: v.validRanges))
                }
                if probe.shortLexPrecedes(current),
                   let output = try? Interpreters.materialize(gen, with: tree, using: probe),
                   property(output) == false
                {
                    latestOutput = output
                    current = probe
                    progress = true
                } else {
                    rejectCache.insert(probe)
                }
            }
        }

        if progress, let output = latestOutput {
            return (current, output)
        }
        return nil
    }
}
