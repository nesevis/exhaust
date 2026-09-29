//
//  BoundValueCompositionTypes.swift
//  Exhaust
//

// MARK: - Bound Value Composition Types

/// Where one composition sits in a chain of nested binds. Each case fixes the upstream encoder, whether the controller's current value is a candidate, and whether a lift may descend into a nested bind.
package enum BoundValueStage: String, Hashable, Sendable {
    /// The dispatched bind has no composable nested bind. Binary search over the controller, then a terminal search over the bound leaves.
    case single
    /// The dispatched bind, whose bound subtree holds one composable nested bind. Every lift descends, so the controller can move against a nested one.
    case chainRoot
    /// A nested bind with a further composable nested bind beneath it. Its current value stays a candidate so deeper controllers can move while it holds.
    case chainInterior
    /// The deepest composable nested bind. Every lift ends in a terminal search.
    case chainTail

    /// Whether the controller is enumerated across its domain rather than binary searched toward its target.
    var searchesWholeDomain: Bool {
        switch self {
            case .single:
                false
            case .chainRoot, .chainInterior, .chainTail:
                true
        }
    }

    var includesCurrentController: Bool {
        switch self {
            case .chainInterior:
                true
            case .single, .chainRoot, .chainTail:
                false
        }
    }

    var canRecurseIntoNestedBind: Bool {
        switch self {
            case .chainRoot, .chainInterior:
                true
            case .single, .chainTail:
                false
        }
    }
}

/// State shared by every composition in one chain of nested binds.
struct BoundValueChain {
    let gen: AnyGenerator
    let upstreamBudget: Int
    /// The live sequence's length at dispatch. Terminal searches reject lifts longer than this; intermediate lifts may exceed it while a deeper controller compensates.
    let rootSequenceCount: Int
    /// Fingerprints of the binds already composed on the path from the root. A repeat marks recursive generator expansion.
    let seenBindFingerprints: Set<UInt64>
    /// Shared by every stage of every composition the machine builds in one run.
    let buildTally: BoundValueBuildTally
    /// Nesting depth of the stage this chain builds, zero at the dispatched bind.
    let depth: Int
    /// Shared by every stage of one dispatch of a nested chain. A single bind's composition does not draw from it.
    let buildPool: CompositionBuildPool

    /// The chain one level deeper, with the nested bind's fingerprint recorded.
    func descending(into fingerprint: UInt64) -> BoundValueChain {
        var fingerprints = seenBindFingerprints
        fingerprints.insert(fingerprint)
        return BoundValueChain(
            gen: gen,
            upstreamBudget: upstreamBudget,
            rootSequenceCount: rootSequenceCount,
            seenBindFingerprints: fingerprints,
            buildTally: buildTally,
            depth: depth + 1,
            buildPool: buildPool
        )
    }

    /// Whether a terminal search may run on a lift of this length. Only terminal searches are gated, so an intermediate lift can grow while a deeper controller compensates.
    func admitsTerminalSearch(liftedSequenceCount: Int) -> Bool {
        liftedSequenceCount <= rootSequenceCount
    }
}

/// A controller candidate materialized through the generator, with the dispatched bind located again in the lifted graph.
struct LiftedBind {
    let sequence: ChoiceSequence
    let tree: ChoiceTree
    let graph: ChoiceGraph
    /// The dispatched bind's node ID in ``graph``, which can differ from its ID in the parent graph.
    let bindNodeID: Int
    /// Sequence positions of the bind's bound subtree.
    let boundRange: ClosedRange<Int>
}

/// The first step of a downstream build: a located lift, or the outcome that ended the build.
enum BoundValueLift {
    case lifted(LiftedBind)
    case failed(BoundValueBuildOutcome)
}

/// How one downstream build ended. Every build records exactly one outcome; only ``BoundValueBuildOutcome/nestedStage`` and ``BoundValueBuildOutcome/terminalSearch`` carry a downstream.
struct BoundValueBuild {
    let outcome: BoundValueBuildOutcome
    let downstream: (encoder: EncoderDispatch, scope: EncoderInput)?

    init(
        outcome: BoundValueBuildOutcome,
        downstream: (encoder: EncoderDispatch, scope: EncoderInput)? = nil
    ) {
        self.outcome = outcome
        self.downstream = downstream
    }
}

/// Counts downstream build outcomes across one reduction run, for ``ReductionStats/boundValueBuildOutcomes``. A class so every stage of every composition records into the machine's single instance.
///
/// Every build materializes the generator once before it records its outcome, so ``total`` is the run's ``MaterializationSite/boundValueLift`` count. Builds in a pass cut short by the deadline are included.
final class BoundValueBuildTally {
    private(set) var counts: [BoundValueBuildRecord: Int] = [:]
    private(set) var total = 0

    func record(_ stage: BoundValueStage, _ outcome: BoundValueBuildOutcome) {
        counts[BoundValueBuildRecord(stage: stage, outcome: outcome), default: 0] += 1
        total += 1
    }
}

// MARK: - Nested Chain Limits

/// Stage turns and build limits for one composition in a chain of nested compositions.
///
/// Nesting multiplies each level's builds, and every build materializes the generator. The per-start limit keeps one level from spending the chain's budget; the shared pool bounds the chain's total however deep it nests. Stage turns keep one controller tuple from consuming the root's probe cap while every downstream iterator stays available for later turns.
struct NestedChainLimits {
    /// Probes a downstream stage emits in one turn before the next stage takes over.
    let probesPerStageTurn: Int
    /// Builder calls at this level per ``GraphComposedEncoder/start(scope:)``, counting builds that return nil. Unlike `upstreamBudget`, a failed build counts, since the builder may materialize before it fails.
    let maxBuildsPerStart: Int
    /// Builder calls left to every composition in the chain, counting builds that return nil and builds whose downstream search emits nothing.
    let buildPool: CompositionBuildPool

    /// Takes one build for a composition that has made `buildsThisStart` builds since its last start, returning false when the per-start limit or the shared pool is spent. The pool is drawn from only when the per-start limit admits the build.
    func consumeBuild(afterBuildsThisStart buildsThisStart: Int) -> Bool {
        buildsThisStart < maxBuildsPerStart && buildPool.consume()
    }
}

// MARK: - Build Pool

/// Builder calls left to one dispatch of a composition and every composition nested below it.
///
/// A class so that nested compositions, which are copied into ``EncoderDispatch`` values, all draw from the root's count. Nesting otherwise multiplies each level's builds, so a per-level limit alone does not bound the total.
final class CompositionBuildPool {
    private(set) var remaining: Int

    init(capacity: Int) {
        remaining = capacity
    }

    /// Takes one build from the pool, returning false when none remain.
    func consume() -> Bool {
        guard remaining > 0 else {
            return false
        }
        remaining -= 1
        return true
    }
}
