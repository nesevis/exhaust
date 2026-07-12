// The dedup-shaped-input archetype (matrix fixture MX2b, "DedupGate"): the trigger is a shape uniform sampling rarely produces and mutation disassembles readily, exercising the unique/CGS interplay under mutation from the input side.
//
// ## Shape Coordinates
//
// Trigger class: all-distinct input shape. Coverage surface: the count guard lights on any input of 10 or more elements; the distinctness conjunct lights only when the fault fires. Vocabulary: one `.int` array generator. Argument domain: elements 0...9. Length scale: the trigger needs exactly 10 elements of an 8...16 range — inside the range, but pinned by pigeonhole.
//
// ## Ground-Truth Registry
//
// Fault D2 (all-distinct at depth):
//     Trigger: input count >= 10 with all elements distinct. Over the 0...9 element domain, pigeonhole makes length exactly 10 the only satisfying count: the input must be a permutation of the ten digits.
//     Trigger variable: the (count, distinct-count) pair.
//     Minimal: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9].
//     Effect: throws DedupGateError.
//
// Single planted fault.
//
// ## Blind-Improbability Math
//
// P(length = 10) = 1/9 under the uniform 8...16 length draw, and P(a length-10 draw over ten values is a permutation) = 10!/10^10 ≈ 3.63e-4, so the joint blind rate is ≈ 4.0e-5 per attempt — rare per draw but reliably found at benchmark attempt counts, which is the intended role: a mutation-disassembly probe (reduction must walk the permutation down), not a discovery differential.
//
// Pinned baseline (MX2e, 2026-07-12, seeds 1-20, 10 s, defaults): 6/20 — mid-window, acceptable only because D2 joins no gate; retune toward the sentinel side (count >= 9) before it ever does.

import Exhaust

/// A pure function faulting on all-distinct inputs of ten or more elements.
public enum DedupGate {
    /// Counts distinct elements and faults on the all-distinct shape.
    ///
    /// - Throws: ``DedupGateError`` when the input has 10 or more elements, all distinct.
    public static func ingest(_ values: [Int]) throws -> Int {
        let distinctCount = Set(values).count
        // Fault D2: the outer count guard is common; the distinctness conjunct lights only when the fault fires.
        if values.count >= 10, distinctCount == values.count {
            throw DedupGateError()
        }
        return distinctCount
    }
}

/// Fault D2's observable effect.
public struct DedupGateError: Error, Equatable, Sendable {
    public init() {}
}

/// The generator and ground-truth minimal reproducer for ``DedupGate``.
public enum DedupGateFixture {
    /// Elements 0...9, lengths 8...16.
    public static var valuesGenerator: ReflectiveGenerator<[Int]> {
        .int(in: 0 ... 9).array(length: 8 ... 16)
    }

    /// Fault D2's minimal form: the ascending permutation of the ten digits.
    public static let reproducerD2 = Array(0 ... 9)
}
