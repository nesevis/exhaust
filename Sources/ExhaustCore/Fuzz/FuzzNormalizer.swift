// Post-reduction cluster normalization for `#explore(time:)`.
//
// Reduction on a real SUT is not guaranteed canonical: a masked-bit gate can stall at
// `flags: 171` when `flags: 3` suffices, and every distinct stall the frontier heuristic then
// mints as a first-class cluster — the inflated-bug-count failure mode users punish hardest.
// The pass here is the Exhaust translation of test-case normalization (Groce, Holmes, Kellar,
// "One Test to Rule Them All", ISSTA 2017): a rewrite pass distinct from and after reduction
// that re-drives each value of the reduced form toward its minimal still-failing bit pattern,
// so every member of one fault converges on one canonical form before cluster identity is
// computed. Their measured slippage for normalization (19.3%/12.5%) was lower than the ~30%
// of property-only reduction itself, so the pass adds no categorically new risk; the post-hoc
// coverage signature and the "likely same" tier remain the safety net for a genuine merge of
// distinct faults.
//
// Per-value minimization is a semantic-simplest probe followed by a greedy bit-clear loop to
// fixpoint. Clearing a set bit always lowers the unsigned pattern, so the loop is monotone and
// needs no backtracking; for mask gates (`flags & 0b11 != 0`) and threshold gates (`> 240`,
// `< 16`) it lands exactly on the shortlex-minimal still-failing value, which is where the
// reducer's own canonical forms already sit. Every probe re-materializes in `.exact` mode —
// a value rewrite that would change structure (a bind input, a coupled length) is rejected by
// the materializer before the property ever runs — and must fail with the original symptom.

import Foundation

/// Canonicalizes a reduced counterexample before it can mint a new fault cluster. See the file header for the mechanism and its provenance.
package enum FuzzNormalizer {
    /// A normalized reduced form: the canonical sequence with the tree and value from its accepting materialization.
    package struct NormalizedForm<Output> {
        package let sequence: ChoiceSequence
        package let tree: ChoiceTree
        package let value: Output
    }

    /// Bounds the per-field probe count. A 64-bit pattern admits at most 64 clears per pass and the fixpoint loop rarely needs more than two passes; the cap exists so a pathological property cannot turn one normalization into thousands of evaluations.
    package static let maxProbesPerField = 128

    /// Re-drives each `.value` entry of `reducedSequence` toward its minimal still-failing bit pattern, one field at a time in sequence order.
    ///
    /// Returns nil when no rewrite survived — the reduced form was already canonical, or every candidate stopped failing (or slipped to a different symptom) and the caller keeps the original. Results are cached by the reduced sequence's Zobrist hash: at fuzzing volume the same stalled forms recur constantly, and Groce et al. measured 99.6% of normalizations as cache hits.
    ///
    /// - Parameters:
    ///   - reducedSequence: The reduced counterexample's flattened choice sequence.
    ///   - erasedGen: The run's generator, already erased.
    ///   - symptom: The original failure's symptom; a probe counts only when it fails with this same symptom, keeping cross-fault slippage out of the pass.
    ///   - property: The property under test. Probes run unattributed — no coverage bracket.
    ///   - cache: Zobrist-keyed normalization results shared across the run's reduction tasks. The stored value is the normalized sequence, or nil when normalization found nothing better.
    package static func normalize<Output>(
        reducedSequence: ChoiceSequence,
        erasedGen: AnyGenerator,
        symptom: FailureSymptom,
        property: (Output) -> FuzzVerdict,
        cache: SendableBox<[UInt64: ChoiceSequence?]>
    ) -> NormalizedForm<Output>? {
        let sequenceHash = ZobristHash.hash(of: reducedSequence)
        let cached = cache.withValue { $0[sequenceHash] }
        if let cached {
            guard let normalizedSequence = cached else {
                return nil
            }
            return materializeForm(normalizedSequence, erasedGen: erasedGen)
        }

        var current = reducedSequence
        var acceptedForm: NormalizedForm<Output>?
        for index in current.indices {
            guard case let .value(entry) = current[index] else {
                continue
            }
            var pattern = entry.choice.bitPattern64
            let range = entry.validRange ?? entry.choice.tag.bitPatternRange
            var probesRemaining = maxProbesPerField

            func probe(_ candidatePattern: UInt64) -> NormalizedForm<Output>? {
                guard probesRemaining > 0, candidatePattern != pattern, range.contains(candidatePattern) else {
                    return nil
                }
                probesRemaining -= 1
                var candidate = current
                candidate[index] = .value(ChoiceSequenceValue.Value(
                    choice: ChoiceValue(candidatePattern, tag: entry.choice.tag),
                    validRange: entry.validRange,
                    isRangeExplicit: entry.isRangeExplicit
                ))
                guard let form: NormalizedForm<Output> = materializeForm(candidate, erasedGen: erasedGen) else {
                    return nil
                }
                guard case let .fail(probeSymptom) = property(form.value), probeSymptom == symptom else {
                    return nil
                }
                return form
            }

            // The one-probe happy path: most stalled fields accept the semantically simplest value outright.
            if let form = probe(entry.choice.semanticSimplest.bitPattern64) {
                pattern = entry.choice.semanticSimplest.bitPattern64
                current = replacing(current, at: index, with: pattern, entry: entry)
                acceptedForm = form
                continue
            }

            // Greedy bit-clear to fixpoint: retry every set bit after each acceptance, since a
            // higher bit can become clearable only once a lower one is gone (and vice versa).
            var clearedAny = true
            while clearedAny, probesRemaining > 0 {
                clearedAny = false
                for bit in (0 ..< 64).reversed() where pattern & (1 << bit) != 0 {
                    let candidatePattern = pattern & ~(UInt64(1) << bit)
                    if let form = probe(candidatePattern) {
                        pattern = candidatePattern
                        current = replacing(current, at: index, with: pattern, entry: entry)
                        acceptedForm = form
                        clearedAny = true
                    }
                }
            }
        }

        guard let acceptedForm else {
            cache.withValue { $0[sequenceHash] = ChoiceSequence?.none }
            return nil
        }
        let normalizedSequence = current
        cache.withValue { $0[sequenceHash] = normalizedSequence }
        return acceptedForm
    }

    /// Materializes a candidate sequence in `.exact` mode, casting the erased value back to the property's output type.
    private static func materializeForm<Output>(
        _ sequence: ChoiceSequence,
        erasedGen: AnyGenerator
    ) -> NormalizedForm<Output>? {
        let result = Materializer.materializeAny(erasedGen, prefix: sequence, mode: .exact)
        guard case let .success(anyValue, tree, _) = result, let value = anyValue as? Output else {
            return nil
        }
        return NormalizedForm(sequence: sequence, tree: tree, value: value)
    }

    /// Returns `sequence` with the value entry at `index` rewritten to `pattern`, keeping the entry's range metadata.
    private static func replacing(
        _ sequence: ChoiceSequence,
        at index: Int,
        with pattern: UInt64,
        entry: ChoiceSequenceValue.Value
    ) -> ChoiceSequence {
        var result = sequence
        result[index] = .value(ChoiceSequenceValue.Value(
            choice: ChoiceValue(pattern, tag: entry.choice.tag),
            validRange: entry.validRange,
            isRangeExplicit: entry.isRangeExplicit
        ))
        return result
    }
}
