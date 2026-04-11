//
//  GraphLockstepEncoder.swift
//  Exhaust
//

// MARK: - Graph Lockstep Encoder

/// Reduces same-typed sibling values in lockstep, moving all values in a group by the same delta simultaneously.
///
/// Each suffix window of a tandem group is searched independently to skip near-target leaders that would otherwise block the whole set. Preserves relative relationships between coupled leaves — the property may constrain siblings to be equal or related.
///
/// This is a value encoder: the delta magnitude is above the opacity boundary and requires predicate feedback to find.
///
/// Candidate construction lives in `GraphLockstepEncoder+Probing.swift`.
struct GraphLockstepEncoder: GraphEncoder {
    let name: EncoderName = .graphLockstep

    // MARK: - State

    var sequence: ChoiceSequence = .init()
    var leafLookup: [Int: (nodeID: Int, mayReshape: Bool)] = [:]
    var mode: Mode = .idle

    enum Mode {
        case idle
        case active(LockstepState)
    }

    struct LockstepWindowPlan {
        let windowIndices: [Int]
        let tag: TypeTag
        let originalEntries: [(index: Int, entry: ChoiceSequenceValue)]
        let searchUpward: Bool
        let distance: UInt64
        let usesFloatingSteps: Bool
    }

    enum LockstepProbePhase {
        case directShot
        case binarySearchStart
        case binarySearch
    }

    struct LockstepState {
        var plans: [LockstepWindowPlan]
        var planIndex: Int
        var probePhase: LockstepProbePhase
        var stepper: MaxBinarySearchStepper
        var lastEmittedCandidate: ChoiceSequence?
        var lastWasDirectShot: Bool
    }

    // MARK: - GraphEncoder

    mutating func start(scope: TransformationScope) {
        sequence = scope.baseSequence
        mode = .idle
        leafLookup = [:]

        guard case let .exchange(.tandem(tandemScope)) = scope.transformation.operation else {
            return
        }

        let graph = scope.graph
        populateLeafLookup(from: tandemScope, graph: graph)
        startLockstep(scope: tandemScope, graph: graph)
    }

    mutating func refreshScope(graph: ChoiceGraph, sequence newSequence: ChoiceSequence) {
        sequence = newSequence
        mode = .idle
        leafLookup = [:]

        let scopes = graph.exchangeScopes()
        guard let tandem = scopes.firstNonNil({ scope -> TandemScope? in
            if case let .tandem(inner) = scope { return inner }
            return nil
        }) else { return }
        populateLeafLookup(from: tandem, graph: graph)
        startLockstep(scope: tandem, graph: graph)
    }

    mutating func nextProbe(lastAccepted: Bool) -> EncoderProbe? {
        guard case var .active(state) = mode else { return nil }

        if lastAccepted, let accepted = state.lastEmittedCandidate {
            sequence = accepted
        }
        state.lastEmittedCandidate = nil
        guard let candidate = nextLockstepProbe(state: &state, lastAccepted: lastAccepted) else {
            mode = .active(state)
            return nil
        }
        mode = .active(state)
        return EncoderProbe(
            candidate: candidate,
            mutation: buildLeafValuesMutation(candidate: candidate)
        )
    }

    // MARK: - Leaf Lookup

    mutating func populateLeafLookup(from tandemScope: TandemScope, graph: ChoiceGraph) {
        for group in tandemScope.groups {
            for entry in group.leaves {
                if let range = graph.nodes[entry.nodeID].positionRange {
                    leafLookup[range.lowerBound] = (entry.nodeID, entry.mayReshapeOnAcceptance)
                }
            }
        }
    }

    func buildLeafValuesMutation(candidate: ChoiceSequence) -> ProjectedMutation {
        var changes: [LeafChange] = []
        for (sequenceIndex, info) in leafLookup {
            guard sequenceIndex < candidate.count, sequenceIndex < sequence.count else { continue }
            guard let candidateChoice = candidate[sequenceIndex].value?.choice,
                  let baselineChoice = sequence[sequenceIndex].value?.choice
            else { continue }
            guard candidateChoice != baselineChoice else { continue }
            changes.append(LeafChange(
                leafNodeID: info.nodeID,
                newValue: candidateChoice,
                mayReshape: info.mayReshape
            ))
        }
        return .leafValues(changes)
    }
}
