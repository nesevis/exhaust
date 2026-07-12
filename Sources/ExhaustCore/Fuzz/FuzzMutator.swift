// Mutation operators over flattened choice sequences for the mutation phase.
//
// There is no operator catalogue to keep correct: the materialiser's three-tier resolution
// (prefix → fallback tree → PRNG) makes any perturbation of the flattened sequence produce a
// valid value, so mutations here only need to be cheap and varied, not structurally sound.
// A mutation that mangles marker pairing degrades to PRNG fallback with low convergence, and
// the corpus tier split routes such children away from parent selection.

/// The perturbation weight class of one fuzz mutation.
///
/// Low preserves the parent's branch decisions and moves only leaf values; medium changes structure (block deletion, duplication, replacement, branch pivot); high corrupts a large region so the materialiser falls through to PRNG for most of the resolution — effectively fresh sampling biased by the surviving fragments, useful for escaping local minima.
package enum MutationIntensity: CaseIterable, Sendable {
    case low
    case medium
    case high
}

/// Pure functions producing mutated choice sequences from corpus parents.
package enum FuzzMutator {
    // MARK: - Entry Point

    /// Returns a mutation of `sequence` at the given intensity.
    ///
    /// Falls back across bands when a band has nothing to work on (a sequence with no `.value` entries cannot take a low-intensity mutation), so the caller always gets a candidate distinct from a zero-length no-op unless the sequence is empty.
    package static func mutate(
        _ sequence: ChoiceSequence,
        intensity: MutationIntensity,
        prng: inout Xoshiro256
    ) -> ChoiceSequence {
        guard sequence.isEmpty == false else {
            return sequence
        }
        switch intensity {
            case .low:
                return mutateValues(sequence, prng: &prng)
            case .medium:
                return mutateStructure(sequence, prng: &prng)
            case .high:
                return corruptRegion(sequence, prng: &prng)
        }
    }

    // MARK: - Low Intensity: Leaf Values

    /// Perturbs one to three `.value` entries, leaving all structural markers in place.
    private static func mutateValues(_ sequence: ChoiceSequence, prng: inout Xoshiro256) -> ChoiceSequence {
        var valueIndices: [Int] = []
        for (index, element) in sequence.enumerated() {
            if case .value = element {
                valueIndices.append(index)
            }
        }
        guard valueIndices.isEmpty == false else {
            // No leaves to move; a structural mutation is the nearest useful neighborhood.
            return mutateStructure(sequence, prng: &prng)
        }

        var result = sequence
        let mutationCount = min(valueIndices.count, 1 + Int(prng.next(upperBound: 3)))
        for _ in 0 ..< mutationCount {
            let target = valueIndices[Int(prng.next(upperBound: UInt64(valueIndices.count)))]
            guard case let .value(entry) = result[target] else {
                continue
            }
            result[target] = .value(perturb(entry, prng: &prng))
        }
        return result
    }

    /// Produces a perturbed copy of one value entry: a fresh in-range draw, a small bit-pattern delta, a boundary-catalogue substitution, or the semantically simplest value.
    private static func perturb(
        _ entry: ChoiceSequenceValue.Value,
        prng: inout Xoshiro256
    ) -> ChoiceSequenceValue.Value {
        let tag = entry.choice.tag
        let range = entry.validRange ?? tag.bitPatternRange
        let newPattern: UInt64
        switch prng.next(upperBound: 4) {
            case 0:
                newPattern = prng.next(in: range)
            case 1:
                // Small modular delta; clamped into the declared range when modular arithmetic would escape the user's domain.
                let delta = 1 &+ prng.next(upperBound: 16)
                let shifted = prng.next(upperBound: 2) == 0
                    ? entry.choice.bitPattern64 &+ delta
                    : entry.choice.bitPattern64 &- delta
                newPattern = entry.allowsModularArithmetic
                    ? shifted
                    : min(max(shifted, range.lowerBound), range.upperBound)
            case 2:
                // Boundary substitution: the same per-type catalogue the covering array draws from plays the dictionary role during fuzzing.
                let catalogue = ProblematicValues.computeProblematicValues(
                    min: range.lowerBound,
                    max: range.upperBound,
                    tag: tag
                )
                newPattern = catalogue.isEmpty
                    ? prng.next(in: range)
                    : catalogue[Int(prng.next(upperBound: UInt64(catalogue.count)))]
            default:
                newPattern = entry.choice.semanticSimplest.bitPattern64
        }
        return ChoiceSequenceValue.Value(
            choice: ChoiceValue(newPattern, tag: tag),
            validRange: entry.validRange,
            isRangeExplicit: entry.isRangeExplicit
        )
    }

    // MARK: - Medium Intensity: Structure

    /// Applies one structural mutation: block deletion, block duplication, block replacement, or branch pivot.
    private static func mutateStructure(_ sequence: ChoiceSequence, prng: inout Xoshiro256) -> ChoiceSequence {
        var result = sequence
        switch prng.next(upperBound: 4) {
            case 0:
                let block = randomBlock(in: result, maximumFraction: 0.25, prng: &prng)
                result.removeSubrange(block)
            case 1:
                let block = randomBlock(in: result, maximumFraction: 0.25, prng: &prng)
                result.insert(contentsOf: result[block], at: block.upperBound)
            case 2:
                let target = randomBlock(in: result, maximumFraction: 0.25, prng: &prng)
                let donor = randomBlock(in: sequence, maximumFraction: 0.25, prng: &prng)
                result.replaceSubrange(target, with: sequence[donor])
            default:
                var branchIndices: [Int] = []
                for (index, element) in result.enumerated() {
                    if case let .branch(branch) = element, branch.branchCount > 1 {
                        branchIndices.append(index)
                    }
                }
                guard branchIndices.isEmpty == false else {
                    let block = randomBlock(in: result, maximumFraction: 0.25, prng: &prng)
                    result.removeSubrange(block)
                    break
                }
                let target = branchIndices[Int(prng.next(upperBound: UInt64(branchIndices.count)))]
                guard case let .branch(branch) = result[target] else {
                    break
                }
                // Pivot to a different branch; the offset draw over count − 1 skips the current identifier.
                let pivot = (branch.id &+ 1 &+ prng.next(upperBound: branch.branchCount - 1)) % branch.branchCount
                result[target] = .branch(.init(
                    id: pivot,
                    branchCount: branch.branchCount,
                    fingerprint: branch.fingerprint
                ))
        }
        return result
    }

    // MARK: - High Intensity: Region Corruption

    /// Corrupts a large contiguous region: either deletes it outright or rewrites every value entry in it with full-range random bit patterns.
    private static func corruptRegion(_ sequence: ChoiceSequence, prng: inout Xoshiro256) -> ChoiceSequence {
        var result = sequence
        let block = randomBlock(in: result, minimumFraction: 0.25, maximumFraction: 0.75, prng: &prng)
        if prng.next(upperBound: 2) == 0 {
            result.removeSubrange(block)
        } else {
            for index in block {
                guard case let .value(entry) = result[index] else {
                    continue
                }
                let tag = entry.choice.tag
                var pattern = prng.next(in: tag.bitPatternRange)
                // Corruption of an explicit, narrower-than-full range clamps back into the user's declared domain: generation must honor declared ranges, and the guided float clamp bypass (which exists so reflected non-finite values survive replay and reduction) would otherwise let corruption smuggle NaN and out-of-range doubles into closures that never generated them. The raw clamp over the monotonic encoding folds non-finite patterns to a bound legally — NaN encodes above +infinity. Non-explicit and full-range entries corrupt freely; their consumers already tolerate the whole domain.
                if entry.isRangeExplicit, let range = entry.validRange, range != tag.bitPatternRange {
                    pattern = Swift.min(Swift.max(pattern, range.lowerBound), range.upperBound)
                }
                result[index] = .value(.init(
                    choice: ChoiceValue(pattern, tag: tag),
                    validRange: entry.validRange,
                    isRangeExplicit: entry.isRangeExplicit
                ))
            }
        }
        return result
    }

    // MARK: - Bind-Boundary Splice

    /// Recombines two corpus entries at a bind boundary: the donor's bound content rides on top of the recipient's inner subtree.
    ///
    /// Returns nil when either sequence lacks a usable `.bind(true)` region — the caller falls back to a plain mutation. Structural mismatch between the recipient's inner value and the donor's bound content is expected; the materialiser degrades it to PRNG fallback with low convergence.
    package static func splice(
        recipient: ChoiceSequence,
        donor: ChoiceSequence,
        prng: inout Xoshiro256
    ) -> ChoiceSequence? {
        guard let recipientBind = randomBindRegion(in: recipient, prng: &prng),
              let donorBind = randomBindRegion(in: donor, prng: &prng)
        else {
            return nil
        }
        var result = ChoiceSequence()
        result.reserveCapacity(
            recipientBind.boundStart + (donorBind.close - donorBind.boundStart) + (recipient.count - recipientBind.close)
        )
        result.append(contentsOf: recipient[..<recipientBind.boundStart])
        result.append(contentsOf: donor[donorBind.boundStart ..< donorBind.close])
        result.append(contentsOf: recipient[recipientBind.close...])
        return result
    }

    /// A bind region in a flattened sequence: `open` is the `.bind(true)` index, `boundStart` the first element of the bound subtree (the inner subtree spans `open + 1 ..< boundStart`), and `close` the matching `.bind(false)`.
    struct BindRegion {
        let open: Int
        let boundStart: Int
        let close: Int
    }

    /// Picks one of the sequence's bind regions at random, or nil when none parses.
    private static func randomBindRegion(in sequence: ChoiceSequence, prng: inout Xoshiro256) -> BindRegion? {
        var regions: [BindRegion] = []
        for (index, element) in sequence.enumerated() {
            guard case .bind(true) = element else {
                continue
            }
            guard let innerEnd = sequence.subtreeEnd(startingAt: index + 1),
                  let close = matchingBindClose(in: sequence, openIndex: index),
                  innerEnd <= close
            else {
                continue
            }
            regions.append(BindRegion(open: index, boundStart: innerEnd, close: close))
        }
        guard regions.isEmpty == false else {
            return nil
        }
        return regions[Int(prng.next(upperBound: UInt64(regions.count)))]
    }

    /// Finds the `.bind(false)` matching the `.bind(true)` at `openIndex`, balancing all marker kinds.
    private static func matchingBindClose(in sequence: ChoiceSequence, openIndex: Int) -> Int? {
        var depth = 0
        var index = openIndex
        while index < sequence.count {
            switch sequence[index] {
                case .group(true), .sequence(true, validRange: _, isLengthExplicit: _), .bind(true):
                    depth += 1
                case .group(false), .sequence(false, validRange: _, isLengthExplicit: _), .bind(false):
                    depth -= 1
                    if depth == 0 {
                        if case .bind(false) = sequence[index] {
                            return index
                        }
                        return nil
                    }
                case .value, .just, .branch:
                    break
            }
            index += 1
        }
        return nil
    }

    // MARK: - Block Selection

    /// Picks a random contiguous block whose length is bounded by the given fractions of the sequence length (always at least one element).
    private static func randomBlock(
        in sequence: ChoiceSequence,
        minimumFraction: Double = 0,
        maximumFraction: Double,
        prng: inout Xoshiro256
    ) -> Range<Int> {
        let count = sequence.count
        let minimumLength = max(1, Int(Double(count) * minimumFraction))
        let maximumLength = max(minimumLength, Int(Double(count) * maximumFraction))
        let length = minimumLength + Int(prng.next(upperBound: UInt64(maximumLength - minimumLength + 1)))
        let start = Int(prng.next(upperBound: UInt64(count - length + 1)))
        return start ..< start + length
    }
}
