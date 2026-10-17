//
//  BoundValueCompositionTypes.swift
//  Exhaust
//

// MARK: - Bound Value Composition Types

/// State shared by every composition in one chain of nested binds.
struct BoundValueChain {
    let gen: AnyGenerator
    let upstreamBudget: Int
    /// The dispatch incumbent bounds terminal length and fixed-prefix comparisons. Intermediate lifts may grow while a deeper controller compensates.
    let rootSequence: ChoiceSequence
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
            rootSequence: rootSequence,
            seenBindFingerprints: fingerprints,
            buildTally: buildTally,
            depth: depth + 1,
            buildPool: buildPool
        )
    }

    /// Whether a terminal search may run on a lift of this length. Only terminal searches are gated, so an intermediate lift can grow while a deeper controller compensates.
    func admitsTerminalSearch(liftedSequenceCount: Int) -> Bool {
        liftedSequenceCount <= rootSequence.count
    }
}

/// Counts downstream build outcomes across one reduction run, for ``ReductionStats/boundValueBuildOutcomes``. A class so every stage of every composition records into the machine's single instance.
///
/// Attempts are recorded immediately before lifting, independently of completed build outcomes. ``total`` alone supplies the run's ``MaterializationSite/boundValueLift`` count; outcome entries describe the same work and are never added to it.
final class BoundValueBuildTally {
    private(set) var counts: [BoundValueBuildRecord: Int] = [:]
    private(set) var total = 0

    /// Records spent work before the engine invokes its lift, including attempts that produce no downstream stage.
    func recordAttempt() {
        total += 1
    }

    /// Records one completed build without counting another materialization. Nested compositions and terminal searches remain separate diagnostic outcomes.
    func record(_ stage: BoundValueStage, build: DownstreamBuild) {
        let outcome: BoundValueBuildOutcome = switch build {
            case .stage(encoder: .composed, scope: _):
                .nestedStage
            case .stage:
                .terminalSearch
            case .failed(.materializationFailed):
                .materializationFailed
            case .failed(.liftedTooLong):
                .liftedTooLong
            case .failed(.bindNotFound):
                .bindNotFound
            case .failed(.noDownstreamLeaves):
                .noDownstreamLeaves
            case .failed(.nonImprovingPrefix):
                .nonImprovingPrefix
            case .failed(.sinkValueMismatch):
                .sinkValueMismatch
        }
        counts[BoundValueBuildRecord(stage: stage, outcome: outcome), default: 0] += 1
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
