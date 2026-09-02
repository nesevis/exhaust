//
//  BacktrackAudition.swift
//  Exhaust
//

/// Draws the arms of a `backtrack` pick without replacement.
///
/// One instance serves one visit of one node. Every interpreter that executes generators drives its audition through this type so that the draw order, the weight recomputation after a removal, and the per-draw PRNG consumption are defined once: ``ValueInterpreter`` and ``ValueAndChoiceTreeInterpreter`` must consume identical draws for their outputs to agree, and sharing the loop makes that structural rather than a parity contract to maintain by hand. The audition owns only selection. Running an arm, deciding that its result is nil, and rolling the interpreter's state back are the caller's, because the state differs per interpreter.
///
/// Zero-weight arms never enter the audition. The only zero-weight arm a backtrack node can carry is the framework-built absent arm of a `failable:` node, and that arm is the exhaustion fallback, not a candidate.
package struct BacktrackAudition {
    private var remaining: ContiguousArray<ReflectiveOperation.PickTuple>
    private var remainingTotalWeight: UInt64

    package init(_ choices: ContiguousArray<ReflectiveOperation.PickTuple>) {
        remaining = ContiguousArray(choices.filter { $0.weight > 0 })
        remainingTotalWeight = remaining.reduce(0) { $0 &+ $1.weight }
    }

    /// Whether every candidate arm has been drawn or excluded.
    package var isExhausted: Bool {
        remainingTotalWeight == 0
    }

    /// Removes an arm the caller has already tried by another route, such as the recorded arm of a materialized prefix.
    package mutating func exclude(id: UInt64) {
        guard let index = remaining.firstIndex(where: { $0.id == id }) else {
            return
        }
        remainingTotalWeight &-= remaining[index].weight
        remaining.remove(at: index)
    }

    /// Draws one arm proportionally to weight among those not yet drawn, or returns nil when none remain.
    ///
    /// Each draw consumes the weighted roll and one further `next()`, the same two values a committed pick consumes for its selection and its jump seed. The second value is returned so a caller that materializes unselected branches can seed them from it.
    package mutating func drawNext(using prng: inout Xoshiro256) -> (arm: ReflectiveOperation.PickTuple, jumpSeed: UInt64)? {
        guard let drawn = WeightedPickSelection.draw(
            from: remaining, totalWeight: remainingTotalWeight, using: &prng
        ) else {
            return nil
        }
        let jumpSeed = prng.next()
        exclude(id: drawn.id)
        return (drawn, jumpSeed)
    }

    /// Takes the next arm in declaration order, or returns nil when none remain. The materializer's minimize mode uses this so a backtrack node minimizes to its lowest producing arm, matching how shortlex orders branch ids.
    package mutating func nextInOrder() -> ReflectiveOperation.PickTuple? {
        guard let first = remaining.first else {
            return nil
        }
        exclude(id: first.id)
        return first
    }

    // MARK: - Exhaustion

    /// The framework-built `.just(nil)` arm of a `failable:` node, or nil on an `always:` node.
    package static func absentArm(
        in choices: ContiguousArray<ReflectiveOperation.PickTuple>
    ) -> ReflectiveOperation.PickTuple? {
        guard choices.first?.isFailable == true, let last = choices.last, last.weight == 0 else {
            return nil
        }
        return last
    }

    /// Whether `arm` is the absent arm of `choices`. A nil result from this arm is the value it exists to produce, not a failed audition.
    package static func isAbsentArm(
        _ arm: ReflectiveOperation.PickTuple,
        in choices: ContiguousArray<ReflectiveOperation.PickTuple>
    ) -> Bool {
        choices.first?.isFailable == true && arm.id == UInt64(choices.count - 1)
    }

    /// Resolves an audition in which every candidate arm produced nil: the absent arm on a `failable:` node, a throw on an `always:` node.
    ///
    /// `reportingDiagnostic` fires the node's call-site hook before the throw. The generation interpreters pass `true` because their throw ends the run and the user needs the source line; the materializer passes `false` because its throw only rejects one candidate.
    package static func resolveExhaustion(
        of choices: ContiguousArray<ReflectiveOperation.PickTuple>,
        reportingDiagnostic: Bool
    ) throws -> ReflectiveOperation.PickTuple {
        if let absent = absentArm(in: choices) {
            return absent
        }
        if reportingDiagnostic {
            choices.first?.onBacktrackExhausted?()
        }
        throw GeneratorError.backtrackExhausted
    }
}
