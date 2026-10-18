//
//  ReductionEncoder.swift
//  Exhaust
//

// MARK: - Encoder Protocol

/// A stateless search definition: what the runner needs to gate an encoder, retain or discard its sources, and build the encoder's reduction for one dispatched scope.
///
/// Every requirement is explicit, with no defaults, so each encoder states what it needs, what it does, and what it supports. Everything the runner asks of an encoder before dispatch is static, so it is read from the encoder's type through ``AnyEncoderScope/typed`` without building one.
///
/// Discovery and ranking belong to the family sources in ``ScopeSource``, not the encoder: one family query finds scopes for several encoders, and a single priority order across them decides which runs first.
protocol ReductionEncoder {
    /// The dispatched unit of work.
    associatedtype Scope

    /// The name the configuration's enabled encoders, statistics, and reports use for this encoder.
    static var name: EncoderName { get }

    // MARK: What It Needs

    /// What the runner checks before dispatching `scope`, beyond its validity. Relax round exploitation applies no gate.
    static func gate(_ scope: Scope) -> DispatchGate

    // MARK: What It Does

    /// Whether the encoder changes the generator's active execution path. On a graph stripped of unselected branches it needs them restored first.
    static var isPathChanging: Bool { get }

    /// The ordering an accepted candidate must satisfy against the incumbent.
    static var admissionOrder: ReductionOrder { get }

    /// The positions whose convergence records an accepted pass on `scope` invalidates, read from the graph before the rebuild, or nil when it invalidates none beyond what the rebuild transfers.
    static func convergenceInvalidatedByAcceptance(_ scope: Scope, in graph: ChoiceGraph) -> ClosedRange<Int>?

    /// Binds the search to `scope` over the snapshot in `input`. Called only for a scope the runner has selected.
    static func reduce(_ scope: Scope, input: EncoderInput) -> Reduction

    // MARK: What It Supports

    /// Whether the scope's target nodes still exist and satisfy its preconditions in `graph`.
    static func isValid(_ scope: Scope, in graph: ChoiceGraph) -> Bool
}

// MARK: - Dispatch Gate

/// A condition the runner evaluates before dispatching a scope, from runner state the encoder cannot see.
enum DispatchGate {
    /// Dispatches whenever the scope is valid.
    case open
    /// Dispatches only as often as the bind's ``BoundValueGate`` allows, and only once the bind's classification shows it lifts at both ends of its controller's range with the same bound shape at each, classifying it first if needed. The gate also supplies the dispatch's ``DispatchBudget``.
    case bindClassification(bindNodeID: Int, upstreamLeafNodeID: Int)
    /// Dispatches only in a cycle with no acceptance yet, and only once the bind inner leaf has stalled.
    case stalledBindInner(leafNodeID: Int)
    /// Skipped once the encoder's consecutive rejected passes reach ``ReductionTuning/migrationDemotionThreshold``. A threshold of zero disables demotion.
    case demotedAfterRejects
}

/// Budgets a ``DispatchGate/bindClassification(bindNodeID:upstreamLeafNodeID:)`` gate resolves for one dispatch.
struct DispatchBudget {
    /// Upstream proposals the outermost level may build. The gate's decayed budget for the bind's fingerprint.
    let upstreamBudget: Int
    /// Probes the whole chain may emit; zero is uncapped. ``ReductionTuning/composedFirstDispatchProbeCap`` on a fingerprint's first dispatch of the run, zero afterwards.
    let totalProbeCap: Int
}

// MARK: - Encoder Input

/// The snapshot the encoder's reduction for a scope is built against: the incumbent's sequence, tree, and graph when the scope is dispatched.
struct EncoderInput {
    let baseSequence: ChoiceSequence
    let tree: ChoiceTree
    let graph: ChoiceGraph
    /// Convergence records keyed by graph node ID, so a value search starts each leaf from its last known floor.
    let warmStartRecords: [Int: ConvergedOrigin]
    /// The run's budgets, the only place they are set.
    let tuning: ReductionTuning
    /// The budgets a ``DispatchGate/bindClassification(bindNodeID:upstreamLeafNodeID:)`` gate resolved for this dispatch; nil for every other gate.
    var dispatchBudget: DispatchBudget?
    /// The run's covering rows. A fresh cache is correct but regenerates rows the run's cache already holds, so every input the runner builds, and every input built from one, passes the run's cache on.
    var coveringRowCache = CoveringRowCache()
}

// MARK: - Graph Helpers

extension ChoiceGraph {
    /// Whether the node is a sequence that still holds more elements than its minimum length.
    func sequenceCanShrink(_ sequenceNodeID: Int) -> Bool {
        guard sequenceNodeID < nodes.count,
              case let .sequence(metadata) = nodes[sequenceNodeID].kind
        else {
            return false
        }
        return UInt64(metadata.elementCount) > (metadata.lengthConstraint?.lowerBound ?? 0)
    }
}
