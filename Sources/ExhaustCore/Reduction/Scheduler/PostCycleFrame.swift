/// Keeps a post-cycle session with its pass policy and remaining actions, independently of the suspended main dispatch loop.
///
/// The continuation is immutable and shared by reference so each cooperative step carries one pointer rather than copying its session, frontier, and remaining actions through the machine's phase enum.
final class PostCycleFrame {
    /// Final reorder owns the rejection cache it temporarily replaces; staged search retains its reservation across arities.
    enum Pass {
        case relation
        case stagedJoint(StagedJointSearch)
        case reorder(savedRejectCache: Set<UInt64>)

        var timing: ReductionMachine.PostCycleTiming {
            switch self {
                case .relation:
                    .relationPass
                case .stagedJoint:
                    .stagedJointPass
                case .reorder:
                    .reorder
            }
        }
    }

    /// Deadline interruption stops search escalation but still completes final presentation work.
    enum CompletionReason {
        case exhausted
        case deadline
    }

    let session: ProbeSession
    let pass: Pass
    let remaining: [ChoiceGraphScheduler.PostCycleAction]

    init(
        session: ProbeSession,
        pass: Pass,
        remaining: [ChoiceGraphScheduler.PostCycleAction]
    ) {
        self.session = session
        self.pass = pass
        self.remaining = remaining
    }

    /// Preserves the owning timing bucket while yielding between encoding and decoding.
    func step(state: inout ReductionMachine) -> ReductionMachine.Transition {
        switch session.step(state: &state) {
            case let .encoded(encoder, cacheHit):
                return .postCycleEncoded(owner: pass.timing, encoder: encoder, cacheHit: cacheHit)
            case let .decoded(encoder, accepted):
                return .postCycleDecoded(owner: pass.timing, encoder: encoder, accepted: accepted)
            case .finished:
                return complete(state: &state, reason: .exhausted)
        }
    }

    /// Applies each pass's report policy on both normal completion and interruption; only exhaustion can start another numeric stage.
    func complete(state: inout ReductionMachine, reason: CompletionReason) -> ReductionMachine.Transition {
        let report = switch (pass, reason) {
            case (.reorder, .deadline):
                session.runToCompletion(state: &state)
            default:
                session.report()
        }
        switch pass {
            case .relation:
                state.finishRelationReport(report)
                state.resumePostCycle(remaining: remaining)
                return .relationPassCompleted(accepted: report.anyAccepted)
            case var .stagedJoint(search):
                state.applyPostCycleReport(report)
                if report.anyAccepted {
                    state.invalidateAfterCoupledAcceptance()
                    state.resumePostCycle(remaining: remaining)
                    return .stagedJointPassCompleted(accepted: true)
                }
                guard reason == .exhausted else {
                    state.resumePostCycle(remaining: remaining)
                    return .stagedJointPassCompleted(accepted: false)
                }
                return state.advanceStagedJointPass(report: report, search: &search, remaining: remaining)
            case let .reorder(savedRejectCache):
                state.finishReorderReport(report, savedRejectCache: savedRejectCache)
                return state.completeReorderPass(accepted: report.anyAccepted)
        }
    }
}
