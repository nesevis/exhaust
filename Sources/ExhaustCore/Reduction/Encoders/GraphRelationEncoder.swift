//
//  GraphRelationEncoder.swift
//  Exhaust
//

// MARK: - Graph Relation Encoder

/// Reduces a stall-converged leaf pair jointly along its inferred rational relation.
///
/// For a pair whose current semantic magnitudes are `(numerator·scale, denominator·scale)`, candidates hold the reduced ratio fixed and vary the scale factor: `(numerator·k, denominator·k)` for `k` below the current scale, written back as bit patterns offset from each leaf's semantic-zero pattern. The search runs in delta space (`k = scale − delta`) so the direct shot at full distance probes the line's minimum `k = 1` first, and the binary search finds the largest accepted delta, mirroring the lockstep idiom.
///
/// The relation is a guess read off the current values, certified only by the oracle. A wrong inference costs one direct-shot probe plus a short binary search, all rejected. ``RelationQuery``'s stall gate ensures the encoder only runs where every other value move has already been certified futile.
///
/// This is a value encoder: the surviving scale factor is above the opacity boundary and requires predicate feedback to find.
struct GraphRelationEncoder: GraphEncoder {
    let name: EncoderName = .relationSearch

    // MARK: - State

    var valueState = ValueEncoderState()
    var mode: Mode = .idle

    enum Mode {
        case idle
        case active(RelationState)
    }

    /// A pair plan with pre-resolved sequence indices for candidate construction.
    struct RelationPlan {
        let firstIndex: Int
        let secondIndex: Int
        let numerator: UInt64
        let denominator: UInt64
        let scale: UInt64
    }

    /// Tracks whether the encoder is in the direct-shot phase (full distance, scale factor one) or binary search refinement.
    enum RelationProbePhase {
        case directShot
        case binarySearchStart
        case binarySearch
    }

    /// Holds the per-scope mutable state for the relation encoder's probe loop.
    struct RelationState {
        var plans: [RelationPlan]
        var planIndex: Int
        var probePhase: RelationProbePhase
        var stepper: BinarySearchStepper
        var lastEmittedCandidate: ChoiceSequence?
        var lastWasDirectShot: Bool
    }

    // MARK: - GraphEncoder

    mutating func start(scope: EncoderInput) {
        valueState.reset(sequence: scope.baseSequence)
        mode = .idle

        guard case let .exchange(.relation(relationScope)) = scope.transformation.operation else {
            return
        }

        let graph = scope.graph
        var plans: [RelationPlan] = []
        for pair in relationScope.pairs {
            guard let firstRange = graph.nodes[pair.first.nodeID].positionRange,
                  let secondRange = graph.nodes[pair.second.nodeID].positionRange
            else {
                continue
            }
            valueState.registerLeaf(nodeID: pair.first.nodeID, mayReshape: pair.first.mayReshapeOnAcceptance, graph: graph)
            valueState.registerLeaf(nodeID: pair.second.nodeID, mayReshape: pair.second.mayReshapeOnAcceptance, graph: graph)
            plans.append(RelationPlan(
                firstIndex: firstRange.lowerBound,
                secondIndex: secondRange.lowerBound,
                numerator: pair.numerator,
                denominator: pair.denominator,
                scale: pair.scale
            ))
        }

        guard plans.isEmpty == false else {
            return
        }

        mode = .active(RelationState(
            plans: plans,
            planIndex: 0,
            probePhase: .directShot,
            stepper: BinarySearchStepper(lo: 0, hi: 0, direction: .findLargest),
            lastEmittedCandidate: nil,
            lastWasDirectShot: false
        ))
    }

    mutating func nextProbe(into candidate: inout ChoiceSequence, lastAccepted: Bool) -> EncoderProbe? {
        guard case var .active(state) = mode else {
            return nil
        }

        if lastAccepted, let accepted = state.lastEmittedCandidate {
            valueState.sequence = accepted
        }
        state.lastEmittedCandidate = nil
        guard let built = nextRelationProbe(state: &state, lastAccepted: lastAccepted) else {
            mode = .active(state)
            return nil
        }
        candidate = built
        state.lastEmittedCandidate = candidate
        let mutation = valueState.buildLeafValuesMutation(candidate: candidate)
        mode = .active(state)
        return mutation
    }

    // MARK: - Probe Loop

    private mutating func nextRelationProbe(
        state: inout RelationState,
        lastAccepted: Bool
    ) -> ChoiceSequence? {
        while state.planIndex < state.plans.count {
            let plan = state.plans[state.planIndex]
            switch state.probePhase {
                case .directShot:
                    // Full distance probes the line's minimum, scale factor one.
                    if let candidate = makeRelationCandidate(plan: plan, delta: plan.scale - 1) {
                        state.lastEmittedCandidate = candidate
                        state.lastWasDirectShot = true
                        state.probePhase = .binarySearchStart
                        return candidate
                    }
                    state.probePhase = .binarySearchStart
                    continue

                case .binarySearchStart:
                    // A direct shot that was accepted cannot be improved on this line.
                    if lastAccepted, state.lastWasDirectShot {
                        state.lastWasDirectShot = false
                        state.planIndex += 1
                        state.probePhase = .directShot
                        continue
                    }
                    state.lastWasDirectShot = false

                    state.stepper = BinarySearchStepper(lo: 0, hi: plan.scale - 1, direction: .findLargest)
                    guard let firstDelta = state.stepper.start() else {
                        state.planIndex += 1
                        state.probePhase = .directShot
                        continue
                    }
                    state.probePhase = .binarySearch
                    if let candidate = makeRelationCandidate(plan: plan, delta: firstDelta) {
                        state.lastEmittedCandidate = candidate
                        return candidate
                    }
                    continue

                case .binarySearch:
                    guard let nextDelta = state.stepper.advance(lastAccepted: lastAccepted) else {
                        state.planIndex += 1
                        state.probePhase = .directShot
                        continue
                    }
                    if let candidate = makeRelationCandidate(plan: plan, delta: nextDelta) {
                        state.lastEmittedCandidate = candidate
                        return candidate
                    }
                    continue
            }
        }
        return nil
    }

    /// Produces a candidate holding the plan's reduced ratio fixed at scale factor `scale − delta`, or nil when the candidate would leave a leaf's explicit range or fail to improve shortlex.
    private func makeRelationCandidate(plan: RelationPlan, delta: UInt64) -> ChoiceSequence? {
        guard delta > 0, delta < plan.scale else {
            return nil
        }
        let scaleFactor = plan.scale - delta

        var candidate = valueState.sequence
        guard writeScaled(
            magnitude: plan.numerator * scaleFactor,
            at: plan.firstIndex,
            into: &candidate
        ) else {
            return nil
        }
        guard writeScaled(
            magnitude: plan.denominator * scaleFactor,
            at: plan.secondIndex,
            into: &candidate
        ) else {
            return nil
        }

        guard candidate.shortLexPrecedes(valueState.sequence) else {
            return nil
        }
        return candidate
    }

    /// Writes the bit pattern for a semantic magnitude into the candidate at the given index, preserving tag and range metadata. Returns false when the entry is missing or the new value falls outside an explicit range.
    private func writeScaled(
        magnitude: UInt64,
        at sequenceIndex: Int,
        into candidate: inout ChoiceSequence
    ) -> Bool {
        guard sequenceIndex < candidate.count,
              let value = candidate[sequenceIndex].value
        else {
            return false
        }

        let bitPattern = value.choice.semanticSimplest.bitPattern64 &+ magnitude
        let newChoice = ChoiceValue(
            value.choice.tag.makeConvertible(bitPattern64: bitPattern),
            tag: value.choice.tag
        )
        guard value.isRangeExplicit == false || newChoice.fits(in: value.validRange) else {
            return false
        }

        candidate[sequenceIndex] = .value(.init(
            choice: newChoice,
            validRange: value.validRange,
            isRangeExplicit: value.isRangeExplicit
        ))
        return true
    }
}
