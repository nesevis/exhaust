//
//  ReductionStats+Transitions.swift
//  Exhaust
//

// MARK: - Step Timing Recording

extension ReductionStats.StepTimings {
    /// Records elapsed time for a step transition.
    package mutating func record(_ transition: ReductionMachine.Transition, elapsed: UInt64) {
        switch transition {
            case .dispatched:
                dispatch += elapsed
                dispatchCount += 1
            case let .postCycleStarted(owner),
                 let .postCycleEncoded(owner, _, _),
                 let .postCycleDecoded(owner, _, _):
                recordPostCycle(owner: owner, elapsed: elapsed)
            case .passCompleted:
                passApply += elapsed
                passApplyCount += 1
            case .encoded:
                encode += elapsed
                encodeCount += 1
            case .decoded:
                decode += elapsed
                decodeCount += 1
            case .rebuilt:
                rebuild += elapsed
                rebuildCount += 1
            case .convergenceConfirmed:
                convergenceConfirmation += elapsed
            case .improvingPivotsCompleted, .excursionAdvanced, .excursionCompleted:
                relaxRound += elapsed
            case .relationPassCompleted:
                relationPass += elapsed
            case .stagedJointPassCompleted:
                stagedJointPass += elapsed
            case .reorderCompleted:
                reorder += elapsed
            case .sourcesBuilt:
                buildSources += elapsed
            case .cycleStarted, .cycleEnded, .terminated:
                break
        }
    }

    /// Charges setup and intermediate probes to their owning post-cycle pass exactly once.
    private mutating func recordPostCycle(owner: ReductionMachine.PostCycleTiming, elapsed: UInt64) {
        switch owner {
            case .relationPass:
                relationPass += elapsed
            case .stagedJointPass:
                stagedJointPass += elapsed
            case .reorder:
                reorder += elapsed
        }
    }
}
