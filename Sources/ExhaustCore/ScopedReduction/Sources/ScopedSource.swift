//
//  ScopedSource.swift
//  Exhaust
//

// MARK: - Priced Encoder Scope

/// A discovered scope with the priority it advertises for dispatch.
struct PricedEncoderScope {
    let encoderScope: AnyEncoderScope
    let priority: DispatchPriority
}

// MARK: - Sorted Source

/// Yields encoder scopes that were priced and sorted when the source was prepared.
///
/// Priority inspection reads the next encoder scope without consuming it. The invalidation describes everything the source was prepared with and stays available after exhaustion.
final class ScopedSortedSource: ScopedSource {
    private var cursor: BufferedScopeCursor<PricedEncoderScope>
    let invalidation: ScopedSourceInvalidation

    /// - Precondition: `encoderScopes` is already in dispatch order.
    init(_ encoderScopes: [PricedEncoderScope], invalidation: ScopedSourceInvalidation) {
        cursor = BufferedScopeCursor(encoderScopes)
        self.invalidation = invalidation
    }

    var dispatchPriority: DispatchPriority? {
        cursor.peekScope?.priority
    }

    func nextScope() -> PricedEncoderScope? {
        cursor.next()
    }
}

// MARK: - Staged Joint Source

/// Yields the one staged joint checkpoint, discovered the first time the source is peeked or pulled.
///
/// Discovery reads the stall evidence the runner holds: convergence in the graph, and which bound value searches came back fruitless. Its price depends on the discovered candidate pool, so a peek discovers too. A checkpoint equal to the last one searched is not offered again.
final class ScopedStagedJointSource: ScopedSource {
    /// A searched checkpoint: the sequence it was discovered on and what it found.
    struct Checkpoint: Equatable {
        let base: ChoiceSequence
        let scope: ScopedStagedJointEncoder.Scope
    }

    let invalidation: ScopedSourceInvalidation = .anyValueChange

    private let graph: ChoiceGraph
    private let sequence: ChoiceSequence
    private let isFruitlessBind: (UInt64) -> Bool
    private let exhausted: Checkpoint?
    private let tuning: ScopedReductionTuning
    /// The checkpoint, discovered on first read and cleared once pulled.
    private lazy var pending: PricedEncoderScope? = discover()

    /// - Parameters:
    ///   - isFruitlessBind: Whether bound value search came back fruitless for the bind with this fingerprint.
    ///   - exhausted: The checkpoint the staged joint encoder's reducer last searched, if any.
    init(
        graph: ChoiceGraph,
        sequence: ChoiceSequence,
        isFruitlessBind: @escaping (UInt64) -> Bool,
        exhausted: Checkpoint?,
        tuning: ScopedReductionTuning
    ) {
        self.graph = graph
        self.sequence = sequence
        self.isFruitlessBind = isFruitlessBind
        self.exhausted = exhausted
        self.tuning = tuning
    }

    var dispatchPriority: DispatchPriority? {
        pending?.priority
    }

    func nextScope() -> PricedEncoderScope? {
        let next = pending
        pending = nil
        return next
    }

    // MARK: - Helpers

    /// Offers the checkpoint when pairs exist and it differs from the exhausted one. Priced with no benefit and the first stage's budget as cost.
    private func discover() -> PricedEncoderScope? {
        guard tuning.stagedJointProbeBudget > 0 else {
            return nil
        }
        let pairs = ScopedStagedJointQuery.pairs(
            graph: graph,
            isFruitlessBind: isFruitlessBind,
            tuning: tuning
        )
        guard pairs.isEmpty == false else {
            return nil
        }
        let candidatePool = ScopedStagedJointQuery.candidatePool(
            graph: graph,
            isFruitlessBind: isFruitlessBind,
            tuning: tuning
        )
        let scope = ScopedStagedJointEncoder.Scope(pairs: pairs, candidatePool: candidatePool)
        guard exhausted != Checkpoint(base: sequence, scope: scope) else {
            return nil
        }
        let firstStageBudget = ScopedStagedJointEncoder.stageBudget(
            arity: 2,
            candidatePool: candidatePool,
            remaining: tuning.stagedJointProbeBudget,
            calculationsRemaining: tuning.numericJointGroupCalculationLimit,
            tuning: tuning
        )
        return PricedEncoderScope(
            encoderScope: .stagedJoint(scope),
            priority: DispatchPriority(
                structuralBenefit: 0,
                valueBenefit: 0,
                reductionMagnitude: 0,
                estimatedCost: firstStageBudget
            )
        )
    }
}

// MARK: - Invalidation

/// The least graph change that invalidates a family's scopes, which decides whether the family survives a rebuild.
enum ScopedSourceInvalidation {
    /// Any value change: the scopes read leaf values.
    case anyValueChange
    /// A change of leaf kind: the family groups siblings by shape, which a leaf-kind change can invalidate without changing node identities.
    case leafKindChange
    /// Only a structural change: the scopes depend on graph topology alone.
    case structuralChange
}

// MARK: - Family Sources

/// A discovery family that advances in place, so saving sources across a relax round preserves their cursors.
protocol ScopedSource: AnyObject {
    /// Peeking may discover scopes but does not consume the next one.
    var dispatchPriority: DispatchPriority? { get }
    /// The least graph change that requires rediscovering this family's scopes.
    var invalidation: ScopedSourceInvalidation { get }
    /// Requests one scope before ordinary priority ordering resumes.
    var prefersInitialDispatch: Bool { get }

    /// Consumes the next scope, or returns nil after exhaustion.
    func nextScope() -> PricedEncoderScope?
}

extension ScopedSource {
    var prefersInitialDispatch: Bool {
        false
    }
}
