//
//  ScopedEncoder.swift
//  Exhaust
//

// MARK: - Encoder Protocol

/// A stateless search definition: what the runner needs to register an encoder, retain or discard its sources, and build its program for one dispatched scope.
///
/// The runner constructs each encoder once per run with the run's ``ScopedReductionTuning``, which is the only place budgets are set.
///
/// Discovery and ranking belong to the family sources in ``ScopedSource``, not the encoder: one family query finds scopes for several encoders, and a single priority order across them decides which runs first. An encoder holds no per-snapshot state, so one value serves the outer run, relax rounds, and lifted contexts.
protocol ScopedEncoder {
    /// The dispatched unit of work, with any runner-resolved budgets already applied.
    associatedtype Scope

    var name: EncoderName { get }

    /// Whether the encoder's scopes depend on leaf values rather than only on graph topology. A source holding such scopes is prepared again after any value change.
    var isValueDependent: Bool { get }

    /// Binds the search to `scope` over the snapshot in `input`. Called only for a scope the runner has selected.
    func reducer(_ scope: Scope, input: ScopedEncoderInput) -> ScopedReducer
}

// MARK: - Registration

/// Closed registration of encoders. The runner reaches every encoder through an exhaustive `switch`, so the compiler checks registration and dispatch opens no existentials.
enum ScopedEncoderKind {
    case boundValue(ScopedBoundValueEncoder)
    case boundExchange(ScopedBoundExchangeEncoder)
    case bindPivot(ScopedBindPivotEncoder)
    case depthCollapse(ScopedDepthCollapseEncoder)
    case laneCollapse(ScopedLaneCollapseEncoder)
    case valueSearch(ScopedValueSearchEncoder)
    case redistribution(ScopedRedistributionEncoder)
    case lockstep(ScopedLockstepEncoder)
    case relation(ScopedRelationEncoder)
    case stagedJoint(ScopedStagedJointEncoder)
    case removal(ScopedRemovalEncoder)
    case substitution(ScopedSubstitutionEncoder)
    case branchPivot(ScopedBranchPivotEncoder)
    case migration(ScopedMigrationEncoder)
    case swap(ScopedSwapEncoder)
    case reorder(ScopedReorderEncoder)

    /// Every registered encoder, built once from the run's tuning.
    static func registered(tuning: ScopedReductionTuning) -> [ScopedEncoderKind] {
        [
            .boundValue(ScopedBoundValueEncoder(tuning: tuning)),
            .boundExchange(ScopedBoundExchangeEncoder(tuning: tuning)),
            .bindPivot(ScopedBindPivotEncoder(tuning: tuning)),
            .depthCollapse(ScopedDepthCollapseEncoder(tuning: tuning)),
            .laneCollapse(ScopedLaneCollapseEncoder(tuning: tuning)),
            .valueSearch(ScopedValueSearchEncoder(tuning: tuning)),
            .redistribution(ScopedRedistributionEncoder(tuning: tuning)),
            .lockstep(ScopedLockstepEncoder(tuning: tuning)),
            .relation(ScopedRelationEncoder(tuning: tuning)),
            .stagedJoint(ScopedStagedJointEncoder(tuning: tuning)),
            .removal(ScopedRemovalEncoder(tuning: tuning)),
            .substitution(ScopedSubstitutionEncoder(tuning: tuning)),
            .branchPivot(ScopedBranchPivotEncoder(tuning: tuning)),
            .migration(ScopedMigrationEncoder(tuning: tuning)),
            .swap(ScopedSwapEncoder(tuning: tuning)),
            .reorder(ScopedReorderEncoder(tuning: tuning)),
        ]
    }

    var name: EncoderName {
        switch self {
            case let .boundValue(encoder):
                encoder.name
            case let .boundExchange(encoder):
                encoder.name
            case let .bindPivot(encoder):
                encoder.name
            case let .depthCollapse(encoder):
                encoder.name
            case let .laneCollapse(encoder):
                encoder.name
            case let .valueSearch(encoder):
                encoder.name
            case let .redistribution(encoder):
                encoder.name
            case let .lockstep(encoder):
                encoder.name
            case let .relation(encoder):
                encoder.name
            case let .stagedJoint(encoder):
                encoder.name
            case let .removal(encoder):
                encoder.name
            case let .substitution(encoder):
                encoder.name
            case let .branchPivot(encoder):
                encoder.name
            case let .migration(encoder):
                encoder.name
            case let .swap(encoder):
                encoder.name
            case let .reorder(encoder):
                encoder.name
        }
    }

    var isValueDependent: Bool {
        switch self {
            case let .boundValue(encoder):
                encoder.isValueDependent
            case let .boundExchange(encoder):
                encoder.isValueDependent
            case let .bindPivot(encoder):
                encoder.isValueDependent
            case let .depthCollapse(encoder):
                encoder.isValueDependent
            case let .laneCollapse(encoder):
                encoder.isValueDependent
            case let .valueSearch(encoder):
                encoder.isValueDependent
            case let .redistribution(encoder):
                encoder.isValueDependent
            case let .lockstep(encoder):
                encoder.isValueDependent
            case let .relation(encoder):
                encoder.isValueDependent
            case let .stagedJoint(encoder):
                encoder.isValueDependent
            case let .removal(encoder):
                encoder.isValueDependent
            case let .substitution(encoder):
                encoder.isValueDependent
            case let .branchPivot(encoder):
                encoder.isValueDependent
            case let .migration(encoder):
                encoder.isValueDependent
            case let .swap(encoder):
                encoder.isValueDependent
            case let .reorder(encoder):
                encoder.isValueDependent
        }
    }
}

// MARK: - Encoder Input

/// The snapshot a scope's program is built against: the incumbent's sequence, tree, and graph when the scope is dispatched.
struct ScopedEncoderInput {
    let baseSequence: ChoiceSequence
    let tree: ChoiceTree
    let graph: ChoiceGraph
    /// Convergence records keyed by graph node ID, so a value search starts each leaf from its last known floor.
    let warmStartRecords: [Int: ConvergedOrigin]
}

// MARK: - Opportunity

/// One discovered scope, tagged with the encoder that runs it. Family sources yield these in dispatch order.
enum ScopedOpportunity {
    case boundValue(BoundValueScope)
    case boundExchange(BoundExchangeScope)
    case bindPivot(BindPivotScope)
    case depthCollapse(ValueMinimizationScope)
    case laneCollapse(ValueMinimizationScope)
    case valueSearch(ScopedValueSearch.Scope)
    case redistribution(RedistributionScope)
    case lockstep(TandemScope)
    case relation(RelationScope)
    /// A post-cycle checkpoint; no family source yields it.
    case stagedJoint(ScopedStagedJointEncoder.Scope)
    case removal(ScopedRemovalEncoder.Scope)
    case substitution(ScopedSubstitutionEncoder.Scope)
    case branchPivot(ScopedBranchPivotEncoder.Scope)
    case migration(MigrationScope)
    case swap(PermutationScope)
    case reorder(ReorderingScope)

    /// The encoder that runs this opportunity, built from `tuning`.
    func encoder(tuning: ScopedReductionTuning) -> ScopedEncoderKind {
        switch self {
            case .boundValue:
                .boundValue(ScopedBoundValueEncoder(tuning: tuning))
            case .boundExchange:
                .boundExchange(ScopedBoundExchangeEncoder(tuning: tuning))
            case .bindPivot:
                .bindPivot(ScopedBindPivotEncoder(tuning: tuning))
            case .depthCollapse:
                .depthCollapse(ScopedDepthCollapseEncoder(tuning: tuning))
            case .laneCollapse:
                .laneCollapse(ScopedLaneCollapseEncoder(tuning: tuning))
            case .valueSearch:
                .valueSearch(ScopedValueSearchEncoder(tuning: tuning))
            case .redistribution:
                .redistribution(ScopedRedistributionEncoder(tuning: tuning))
            case .lockstep:
                .lockstep(ScopedLockstepEncoder(tuning: tuning))
            case .relation:
                .relation(ScopedRelationEncoder(tuning: tuning))
            case .stagedJoint:
                .stagedJoint(ScopedStagedJointEncoder(tuning: tuning))
            case .removal:
                .removal(ScopedRemovalEncoder(tuning: tuning))
            case .substitution:
                .substitution(ScopedSubstitutionEncoder(tuning: tuning))
            case .branchPivot:
                .branchPivot(ScopedBranchPivotEncoder(tuning: tuning))
            case .migration:
                .migration(ScopedMigrationEncoder(tuning: tuning))
            case .swap:
                .swap(ScopedSwapEncoder(tuning: tuning))
            case .reorder:
                .reorder(ScopedReorderEncoder(tuning: tuning))
        }
    }
}
