//
//  ReductionSession+Timing.swift
//  Exhaust
//

// MARK: - Step Timing

extension ReductionSession {
    /// A ``ReductionStats/StepTimings`` bucket that a span of runner work is charged to.
    ///
    /// Each span runs from the previous charge to the next, so the buckets partition the run's time from the start of ``run()`` onward. The interpreter splits a pass's probing into encode and decode spans itself.
    enum TimingBucket {
        /// Selecting a scope, including skips, exhausted sources, classification, rematerialization, and building the encoder's reduction for the pass.
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
        /// Cycle bookkeeping that no bucket reports: beginning and evaluating a cycle.
        case untimed
    }

    /// Partitions the run's time into ``TimingBucket``s. ``result()`` copies the accumulated timings into the run's statistics.
    struct StepTimer {
        /// Whether statistics are collected. When false, no clock is read.
        let isEnabled: Bool
        var timings = ReductionStats.StepTimings()
        /// When the last span ended.
        private var mark: UInt64 = 0
        /// The post-cycle bucket that every span is charged to while its pass runs.
        private var owner: TimingBucket?

        init(isEnabled: Bool) {
            self.isEnabled = isEnabled
        }

        /// Where the interpreter starts its encode and decode spans, or nil when statistics are not collected.
        var probeMark: UInt64? {
            isEnabled ? mark : nil
        }

        /// Starts the first span at the start of ``ReductionSession/run()``.
        mutating func start() {
            if isEnabled {
                mark = MonotonicClock.nanoseconds()
            }
        }

        /// Charges the time since the previous charge to `bucket`, or to the owning bucket while ``beginOwnership(_:)`` is in effect. Reads no clock unless statistics are collected.
        mutating func charge(_ bucket: TimingBucket) {
            guard isEnabled else {
                return
            }
            let now = MonotonicClock.nanoseconds()
            let elapsed = now - mark
            mark = now
            timings.record(owner ?? bucket, elapsed: elapsed, isCounted: owner == nil)
        }

        /// Charges a pass's encode and decode spans, then resumes from where the interpreter stopped.
        mutating func chargeProbing(_ probeTiming: Reducer.ProbeTiming?) {
            guard let probeTiming else {
                return
            }
            mark = probeTiming.mark
            guard let owner else {
                timings.encode += probeTiming.encodeNanoseconds
                timings.decode += probeTiming.decodeNanoseconds
                timings.encodeCount += probeTiming.encodeCount
                timings.decodeCount += probeTiming.decodeCount
                return
            }
            timings.record(
                owner,
                elapsed: probeTiming.encodeNanoseconds + probeTiming.decodeNanoseconds,
                isCounted: false
            )
        }

        /// Charges every span until the matching ``endOwnership(restoring:)``, nested dispatch and probing included, to `owner`, without counting steps.
        ///
        /// - Returns: The previous owner, for ``endOwnership(restoring:)`` to restore.
        mutating func beginOwnership(_ owner: TimingBucket) -> TimingBucket? {
            let previousOwner = self.owner
            self.owner = self.owner ?? owner
            return previousOwner
        }

        /// Charges the owned work's last span and restores the previous owner.
        mutating func endOwnership(restoring previousOwner: TimingBucket?) {
            if let owner {
                charge(owner)
            }
            owner = previousOwner
        }
    }
}

// MARK: - Recording

private extension ReductionStats.StepTimings {
    /// Adds `elapsed` to the bucket. Uncounted spans belong to an owning post-cycle pass, which reports time only.
    mutating func record(_ bucket: ReductionSession.TimingBucket, elapsed: UInt64, isCounted: Bool) {
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

// MARK: - Post-Cycle Timing

extension ReductionSession.PostCycleAction {
    /// The owner for the whole action, including adoption and rebuilding after a recovered witness.
    var timingBucket: ReductionSession.TimingBucket {
        switch self {
            case .confirmConvergence:
                .convergenceConfirmation
            case .relationPass:
                .relationPass
            case .improvingPivots, .relaxRound:
                .relaxRound
            case .stagedJointPass:
                .stagedJointPass
        }
    }
}
