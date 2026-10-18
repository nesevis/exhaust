//
//  AnyEncoderScope.swift
//  Exhaust
//

/// One discovered scope of any encoder, tagged with the encoder that runs it. Family sources yield these in dispatch order.
///
/// Each encoder's ``ReductionEncoder/Scope`` is its own type, so sources, priority ordering, and the runner hold scopes of different encoders through this closed enum rather than through existentials. Dispatch opens a scope through ``typed`` only when it asks a question of its encoder.
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
    case stagedJoint(StagedJointEncoder.Scope)
    case removal(RemovalEncoder.Scope)
    case substitution(SubstitutionEncoder.Scope)
    case branchPivot(BranchPivotEncoder.Scope)
    case migration(MigrationScope)
    case swap(PermutationScope)
    case reorder(ReorderingScope)

    /// The scope with its encoder's type recovered, through which dispatch asks every question of the encoder. This is the one switch a new encoder adds an arm to.
    var typed: any AnyTypedEncoderScope {
        switch self {
            case let .boundValue(scope):
                TypedEncoderScope<BoundValueEncoder>(scope: scope)
            case let .boundExchange(scope):
                TypedEncoderScope<BoundExchangeEncoder>(scope: scope)
            case let .bindPivot(scope):
                TypedEncoderScope<BindPivotEncoder>(scope: scope)
            case let .depthCollapse(scope):
                TypedEncoderScope<DepthCollapseEncoder>(scope: scope)
            case let .laneCollapse(scope):
                TypedEncoderScope<LaneCollapseEncoder>(scope: scope)
            case let .valueSearch(scope):
                TypedEncoderScope<ValueSearchEncoder>(scope: scope)
            case let .floatSearch(scope):
                TypedEncoderScope<FloatSearchEncoder>(scope: scope)
            case let .redistribution(scope):
                TypedEncoderScope<RedistributionEncoder>(scope: scope)
            case let .lockstep(scope):
                TypedEncoderScope<LockstepEncoder>(scope: scope)
            case let .relation(scope):
                TypedEncoderScope<RelationEncoder>(scope: scope)
            case let .stagedJoint(scope):
                TypedEncoderScope<StagedJointEncoder>(scope: scope)
            case let .removal(scope):
                TypedEncoderScope<RemovalEncoder>(scope: scope)
            case let .substitution(scope):
                TypedEncoderScope<SubstitutionEncoder>(scope: scope)
            case let .branchPivot(scope):
                TypedEncoderScope<BranchPivotEncoder>(scope: scope)
            case let .migration(scope):
                TypedEncoderScope<MigrationEncoder>(scope: scope)
            case let .swap(scope):
                TypedEncoderScope<SwapEncoder>(scope: scope)
            case let .reorder(scope):
                TypedEncoderScope<ReorderEncoder>(scope: scope)
        }
    }

    /// The encoder this scope belongs to, whose static requirements answer every question dispatch asks of the encoder alone.
    var encoder: any ReductionEncoder.Type {
        typed.encoder
    }
}

// MARK: - Typed Scope

/// The questions dispatch asks of one scope, answered by its encoder.
protocol AnyTypedEncoderScope {
    var encoder: any ReductionEncoder.Type { get }
    var gate: DispatchGate { get }
    func isValid(in graph: ChoiceGraph) -> Bool
    func convergenceInvalidatedByAcceptance(in graph: ChoiceGraph) -> ClosedRange<Int>?
    func reduce(input: EncoderInput) -> Reduction
}

/// A scope paired with its encoder's type, so each question is written once, generically.
struct TypedEncoderScope<Encoder: ReductionEncoder>: AnyTypedEncoderScope {
    let scope: Encoder.Scope

    var encoder: any ReductionEncoder.Type {
        Encoder.self
    }

    var gate: DispatchGate {
        Encoder.gate(scope)
    }

    func isValid(in graph: ChoiceGraph) -> Bool {
        Encoder.isValid(scope, in: graph)
    }

    func convergenceInvalidatedByAcceptance(in graph: ChoiceGraph) -> ClosedRange<Int>? {
        Encoder.convergenceInvalidatedByAcceptance(scope, in: graph)
    }

    func reduce(input: EncoderInput) -> Reduction {
        Encoder.reduce(scope, input: input)
    }
}
