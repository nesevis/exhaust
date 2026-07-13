// The collection-length-gate archetype (matrix fixture MX2a, "LengthGate"): the accumulation class transplanted to the value path, with branchless consumption so the length axis stays free of hit-count-bucket ladders.
//
// ## Shape Coordinates
//
// Trigger class: collection-length gate. Coverage surface: flat on length (see Flatness; the empirical check's result is recorded below). Vocabulary: one `.int` array generator. Argument domain: element values 0...9, irrelevant to the trigger. Length scale: the trigger sits at 40 of a 0...48 range — the length axis is the fixture's entire point.
//
// ## Ground-Truth Registry
//
// Fault L (length gate):
//     Trigger: input count >= 40.
//     Trigger variable: values.count.
//     Minimal: 40 zeros.
//     Effect: throws LengthGateError.
//
// Single planted fault; element values feed only the checksum.
//
// ## Flatness
//
// Consumption passes the standard library's `&+` directly to `reduce`, so no fixture-defined code executes per element — the per-element hit-count ladder the design doc warns about (SF6) has no fixture edge to ride. The only branch is the fault comparison itself, which lights nothing until the fault fires. Empirical check (MX2a, 2026-07-12): pinned-length #explore probes at lengths 10, 20, and 39 (500 ms, seed 1, -Onone) each covered exactly 5 edges and admitted exactly 101 corpus entries — no edge and no admission rung varies with length, so the fixture is honestly flat on the length axis. Caveat: the argument holds at -Onone (debug, the production configuration for this mode); an optimized build could specialize `reduce` into this module and reintroduce a per-element counter.
//
// ## Blind Rate (deliberately probable)
//
// Under a uniform 0...48 length draw, P(count >= 40) = 9/49 ≈ 0.18 per attempt — fault L is a reliably-found no-regression sentinel for the length class (MX4b's sign-test set), not a discovery differential. The champion-archive tension it exposes lives in corpus composition (shortlex-minimal parents versus 40-element triggers), which the MX4 arms observe directly.
//
// Pinned baseline (MX2e, 2026-07-12, seeds 1-20, 10 s, defaults): 20/20.

import Exhaust

/// A pure function faulting on inputs of 40 or more elements, consumed branchlessly.
public enum LengthGate {
    /// Sums the input and faults at the length gate.
    ///
    /// - Throws: ``LengthGateError`` when the input has 40 or more elements.
    public static func process(_ values: [Int]) throws -> Int {
        let checksum = values.reduce(0, &+)
        // Fault L: the only branch in the fixture; lights nothing below the gate.
        if values.count >= 40 {
            throw LengthGateError()
        }
        return checksum
    }
}

/// Fault L's observable effect.
public struct LengthGateError: Error, Equatable, Sendable {
    public init() {}
}

/// The generator and ground-truth minimal reproducer for ``LengthGate``.
public enum LengthGateFixture {
    /// Element values 0...9 (irrelevant to the trigger), lengths 0...48.
    public static var valuesGenerator: ReflectiveGenerator<[Int]> {
        .int(in: 0 ... 9).array(length: 0 ... 48)
    }

    /// Fault L's minimal form: 40 zeros.
    public static let reproducerL = [Int](repeating: 0, count: 40)
}
