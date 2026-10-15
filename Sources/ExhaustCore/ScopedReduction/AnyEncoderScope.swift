//
//  AnyEncoderScope.swift
//  Exhaust
//

/// One discovered scope of any encoder, tagged with the encoder that runs it. Family sources yield these in dispatch order.
///
/// Each encoder's ``ScopedEncoder/Scope`` is its own type, so sources, priority ordering, and the runner hold scopes of different encoders through this closed enum rather than through existentials. Dispatch opens a scope through ``typed`` only when it asks a question of its encoder.
enum AnyEncoderScope {
    case boundValue(BoundValueScope)
    case boundExchange(BoundExchangeScope)
    case bindPivot(BindPivotScope)
    case depthCollapse(ValueMinimizationScope)
    case laneCollapse(ValueMinimizationScope)
    case valueSearch(ValueMinimizationScope)
    case floatSearch(FloatMinimizationScope)
    case redistribution(RedistributionScope)
    case lockstep(TandemScope)
    case relation(RelationScope)
    case stagedJoint(ScopedStagedJointEncoder.Scope)
    case removal(ScopedRemovalEncoder.Scope)
    case substitution(ScopedSubstitutionEncoder.Scope)
    case branchPivot(ScopedBranchPivotEncoder.Scope)
    case migration(MigrationScope)
    case swap(PermutationScope)
    case reorder(ReorderingScope)

    /// The scope with its encoder's type recovered, through which dispatch asks every question of the encoder. This is the one switch a new encoder adds an arm to.
    var typed: any AnyTypedEncoderScope {
        switch self {
            case let .boundValue(scope):
                TypedEncoderScope<ScopedBoundValueEncoder>(scope: scope)
            case let .boundExchange(scope):
                TypedEncoderScope<ScopedBoundExchangeEncoder>(scope: scope)
            case let .bindPivot(scope):
                TypedEncoderScope<ScopedBindPivotEncoder>(scope: scope)
            case let .depthCollapse(scope):
                TypedEncoderScope<ScopedDepthCollapseEncoder>(scope: scope)
            case let .laneCollapse(scope):
                TypedEncoderScope<ScopedLaneCollapseEncoder>(scope: scope)
            case let .valueSearch(scope):
                TypedEncoderScope<ScopedValueSearchEncoder>(scope: scope)
            case let .floatSearch(scope):
                TypedEncoderScope<ScopedFloatSearchEncoder>(scope: scope)
            case let .redistribution(scope):
                TypedEncoderScope<ScopedRedistributionEncoder>(scope: scope)
            case let .lockstep(scope):
                TypedEncoderScope<ScopedLockstepEncoder>(scope: scope)
            case let .relation(scope):
                TypedEncoderScope<ScopedRelationEncoder>(scope: scope)
            case let .stagedJoint(scope):
                TypedEncoderScope<ScopedStagedJointEncoder>(scope: scope)
            case let .removal(scope):
                TypedEncoderScope<ScopedRemovalEncoder>(scope: scope)
            case let .substitution(scope):
                TypedEncoderScope<ScopedSubstitutionEncoder>(scope: scope)
            case let .branchPivot(scope):
                TypedEncoderScope<ScopedBranchPivotEncoder>(scope: scope)
            case let .migration(scope):
                TypedEncoderScope<ScopedMigrationEncoder>(scope: scope)
            case let .swap(scope):
                TypedEncoderScope<ScopedSwapEncoder>(scope: scope)
            case let .reorder(scope):
                TypedEncoderScope<ScopedReorderEncoder>(scope: scope)
        }
    }

    /// The encoder this scope belongs to, whose static requirements answer every question dispatch asks of the encoder alone.
    var encoder: any ScopedEncoder.Type {
        typed.encoder
    }
}

// MARK: - Typed Scope

/// The questions dispatch asks of one scope, answered by its encoder.
protocol AnyTypedEncoderScope {
    var encoder: any ScopedEncoder.Type { get }
    var gate: ScopedDispatchGate { get }
    func isValid(in graph: ChoiceGraph) -> Bool
    var rejectionKey: ScopedRejectionKey? { get }
    func convergenceInvalidatedByAcceptance(in graph: ChoiceGraph) -> ClosedRange<Int>?
    func reducer(input: ScopedEncoderInput) -> ScopedReducer
}

/// A scope paired with its encoder's type, so each question is written once, generically.
struct TypedEncoderScope<Encoder: ScopedEncoder>: AnyTypedEncoderScope {
    let scope: Encoder.Scope

    var encoder: any ScopedEncoder.Type {
        Encoder.self
    }

    var gate: ScopedDispatchGate {
        Encoder.gate(scope)
    }

    func isValid(in graph: ChoiceGraph) -> Bool {
        Encoder.isValid(scope, in: graph)
    }

    var rejectionKey: ScopedRejectionKey? {
        Encoder.rejectionKey(scope)
    }

    func convergenceInvalidatedByAcceptance(in graph: ChoiceGraph) -> ClosedRange<Int>? {
        Encoder.convergenceInvalidatedByAcceptance(scope, in: graph)
    }

    func reducer(input: ScopedEncoderInput) -> ScopedReducer {
        Encoder.reducer(scope, input: input)
    }
}
