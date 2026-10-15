//
//  ScopedReductionRunner+Timing.swift
//  Exhaust
//

// MARK: - Step Timing

extension ScopedReductionRunner {
    /// A ``ReductionStats/StepTimings`` bucket that a span of runner work is charged to.
    ///
    /// Each span runs from the previous charge to the next, so the buckets partition the run's time from the start of ``run()`` onward. The interpreter splits a pass's probing into encode and decode spans itself.
    enum TimingBucket {
        /// Selecting a scope, including skips, exhausted sources, classification, rematerialization, and building the encoder's reducer for the pass.
        case dispatch
        /// Applying a completed pass's report.
        case passApply
        case buildSources
        case rebuild
        case convergenceConfirmation
        /// Improving pivots and relax rounds, including a relax round's exploitation dispatch.
        case relaxRound
        case relationPass
        case stagedJointPass
        case reorder
        /// Cycle bookkeeping that no bucket reports: beginning a cycle, evaluating it, and releasing deferral.
        case untimed
    }

    /// Charges the time since the previous charge to `bucket`, or to the owning bucket while ``beginTimingOwnership(_:)`` is in effect. Reads no clock unless stats are collected.
    mutating func chargeElapsed(to bucket: TimingBucket) {
        guard collectStats else {
            return
        }
        let now = MonotonicClock.nanoseconds()
        let elapsed = now - timingMark
        timingMark = now
        stats.stepTimings.record(timingOwner ?? bucket, elapsed: elapsed, isCounted: timingOwner == nil)
    }

    /// Charges a pass's encode and decode spans, then resumes from where the interpreter stopped.
    mutating func chargeProbing(_ probeTiming: ScopedReductionInterpreter.ProbeTiming?) {
        guard let probeTiming else {
            return
        }
        timingMark = probeTiming.mark
        guard let timingOwner else {
            stats.stepTimings.encode += probeTiming.encodeNanoseconds
            stats.stepTimings.decode += probeTiming.decodeNanoseconds
            stats.stepTimings.encodeCount += probeTiming.encodeCount
            stats.stepTimings.decodeCount += probeTiming.decodeCount
            return
        }
        stats.stepTimings.record(
            timingOwner,
            elapsed: probeTiming.encodeNanoseconds + probeTiming.decodeNanoseconds,
            isCounted: false
        )
    }

    /// Charges every span until the matching ``endTimingOwnership(restoring:)``, nested dispatch and probing included, to `owner`, without counting steps.
    ///
    /// - Returns: The previous owner, for ``endTimingOwnership(restoring:)`` to restore.
    mutating func beginTimingOwnership(_ owner: TimingBucket) -> TimingBucket? {
        let previousOwner = timingOwner
        timingOwner = timingOwner ?? owner
        return previousOwner
    }

    /// Charges the owned work's last span and restores the previous owner.
    mutating func endTimingOwnership(restoring previousOwner: TimingBucket?) {
        if let timingOwner {
            chargeElapsed(to: timingOwner)
        }
        timingOwner = previousOwner
    }
}

// MARK: - Recording

private extension ReductionStats.StepTimings {
    /// Adds `elapsed` to the bucket. Uncounted spans belong to an owning post-cycle pass, which reports time only.
    mutating func record(_ bucket: ScopedReductionRunner.TimingBucket, elapsed: UInt64, isCounted: Bool) {
        switch bucket {
            case .dispatch:
                dispatch += elapsed
                if isCounted {
                    dispatchCount += 1
                }
            case .passApply:
                passApply += elapsed
                if isCounted {
                    passApplyCount += 1
                }
            case .buildSources:
                buildSources += elapsed
            case .rebuild:
                rebuild += elapsed
                if isCounted {
                    rebuildCount += 1
                }
            case .convergenceConfirmation:
                convergenceConfirmation += elapsed
            case .relaxRound:
                relaxRound += elapsed
            case .relationPass:
                relationPass += elapsed
            case .stagedJointPass:
                stagedJointPass += elapsed
            case .reorder:
                reorder += elapsed
            case .untimed:
                break
        }
    }
}
