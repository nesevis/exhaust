// Failure handling for the fuzz loop: the backpressure gate, inline reduction, normalization, and cluster classification.

/// The fault side of a run: the backpressure gate, the cluster inventory, and the normalization cache, owned together because every failure passes through all three in that order.
///
/// All of it runs inline on the loop's lane, so none of it is locked. The gate's dispatched-hash set stays separate from the corpus's identity set: it records sequences that reached reduction, not sequences the corpus has seen, and a failure held unreduced is neither.
struct FaultPipeline {
    var gate = ReductionGate()
    let inventory = FaultInventory()
    /// Zobrist-keyed normalization results, so a stalled reduced form that recurs is normalized once.
    var normalizationCache: [UInt64: ChoiceSequence?] = [:]
}

extension FuzzRunner {
    // MARK: - Failure Handling

    /// Dispatches one failing candidate through the backpressure gate: attributed as a duplicate, held unreduced, or reduced and classified. A candidate whose verdict is not a failure is ignored.
    ///
    /// - Parameters:
    ///   - attemptIndex: The attempt the failure was observed at, on the logical run's timeline (``attemptTimelineIndex``). Recovery passes the predecessors' total, so a restored entry's failure never lowers a carried-over cluster's discovery index.
    ///   - countsAsInstance: Whether the failure adds a member to the cluster it lands in. False for a restored entry the predecessor already recorded as failing: that entry landing back in the cluster it was restored into is the same evidence twice, and counting it inflates the carried-over instance and reduction counts on every resume. A restored entry that passed for the predecessor and fails now is evidence this build produced, so it counts.
    func handleFailure(
        _ failing: EvaluatedFuzzCandidate<Output>,
        deferredTreeRebuild: (() -> ChoiceTree?)? = nil,
        parentIndex: Int?,
        phase: FuzzPhase,
        coverageNovel: Bool,
        attemptIndex: Int,
        countsAsInstance: Bool = true
    ) {
        guard case let .fail(symptom) = failing.verdict else {
            return
        }
        // The boost is applied per gate arm rather than up front: a `.duplicate` is a failure the run already accounted for, and boosting on it would credit the same evidence twice while invalidating the tier's prefix sums for a score that does not move.
        switch faults.gate.admit(sequenceHash: failing.sequenceHash, symptom: symptom, coverageNovel: coverageNovel) {
            case .duplicate:
                return
            case .recordUnreduced:
                if let parentIndex {
                    corpus.applyProvisionalFailureBoost(toParentAt: parentIndex)
                }
                faults.inventory.recordUnreduced(
                    symptom: symptom,
                    timestampNanoseconds: monotonicNanoseconds(),
                    attemptIndex: attemptIndex,
                    countsAsInstance: countsAsInstance
                )
            case let .reduce(isEscape):
                if let parentIndex {
                    corpus.applyProvisionalFailureBoost(toParentAt: parentIndex)
                }
                let reductionTree: ChoiceTree
                if let deferredTreeRebuild {
                    guard let rebuilt = deferredTreeRebuild() else {
                        // Divergence on the deferred path: the attempt is already recorded, so the failure is held unreduced rather than dispatched with a placeholder tree.
                        faults.inventory.recordUnreduced(
                            symptom: symptom,
                            timestampNanoseconds: monotonicNanoseconds(),
                            attemptIndex: attemptIndex,
                            countsAsInstance: countsAsInstance
                        )
                        return
                    }
                    reductionTree = rebuilt
                } else {
                    reductionTree = failing.tree
                }
                performReduction(
                    value: failing.value,
                    tree: reductionTree,
                    symptom: symptom,
                    parentIndex: parentIndex,
                    phase: phase,
                    attemptIndex: attemptIndex,
                    wasEscape: isEscape,
                    countsAsInstance: countsAsInstance
                )
        }
    }

    /// Reduces one gated failure inline on the loop's lane: reduce, normalize, capture the post-hoc signature, classify, and apply the classification's feedback before the next attempt.
    ///
    /// Inline execution trades attempts for signal purity: reduction probes never run concurrently with an attempt bracket, so they cannot pollute attempt signatures, and the feedback (failure-boost upgrades, escape-gate outcomes) lands at a deterministic point in the attempt stream. The time spent is accumulated into the reduction timing bucket so the report's throughput and overhead figures keep describing the search pipeline.
    private func performReduction(
        value: Output,
        tree: ChoiceTree,
        symptom: FailureSymptom,
        parentIndex: Int?,
        phase: FuzzPhase,
        attemptIndex: Int,
        wasEscape: Bool,
        countsAsInstance: Bool
    ) {
        let reductionStart = monotonicNanoseconds()
        let reduction = reduceStrategy(tree, value, symptom, Self.reductionProbeWrapper(breadcrumb))
        counts.reductionInvocations += reduction.propertyInvocations
        if reduction.escaped {
            forcedTermination = .uncontainedAsyncWork
        }
        var reducedSequence = reduction.sequence
        var reducedTree = reduction.tree
        var reducedValue = reduction.value

        // Normalization runs only on the would-be-new-cluster event: a reduced form whose key already exists needs no canonicalization, and the containsKey pre-check keeps the probing off the saturated-cluster path entirely.
        // Cluster identity is a cheap structural key over the reduced tree flattened with bind-inners skipped; the reflective description render is deferred to recordReduced and runs only when a new cluster is created. It is computed once here and recomputed only where normalization actually replaced the tree.
        var reducedKey = ChoiceSequence.flatten(reducedTree, skipBindInners: true).clusterKey
        var unnormalizedResidual = false

        // Any probe here can be the invocation whose async work escapes its bound. That work is still running and still recording coverage, so a later invocation would measure it rather than the input. The flag is read at each point that would drive the property again, never snapshotted, because normalization can be what sets it.
        if forcedTermination == nil {
            if faults.inventory.containsKey(reducedKey) == false,
               let normalized: FuzzNormalizer.NormalizedForm<Output> = FuzzNormalizer.normalize(
                   reducedSequence: reducedSequence,
                   erasedGen: erasedGen,
                   symptom: symptom,
                   property: { [self] value, candidate in
                       // A non-failing verdict makes the normalizer reject the variation, so a pass whose probe escaped ends on the reduced form it already has.
                       guard forcedTermination == nil else {
                           return .pass
                       }
                       counts.normalizationInvocations += 1
                       return judge(
                           value,
                           candidateHash: ZobristHash.hash(of: candidate),
                           kind: .normalization,
                           sequence: candidate
                       )
                   },
                   cache: &faults.normalizationCache
               )
            {
                unnormalizedResidual = true
                reducedSequence = normalized.sequence
                reducedTree = normalized.tree
                reducedValue = normalized.value
                reducedKey = ChoiceSequence.flatten(reducedTree, skipBindInners: true).clusterKey
            }
        }

        // Post-reduction classification: one clean-bracket evaluation yields the post-hoc signature. Cluster identity keys on the reduced form; the signature collects within the cluster, where a second distinct one raises the ~paths marker. A cluster classified after an escape carries no signature rather than one measured against uncontained work.
        let signature: BitSet? = forcedTermination == nil
            ? attributedSignature(of: reducedValue, sequence: reducedSequence)
            : nil

        let classification = faults.inventory.recordReduced(
            reducedSequence: reducedSequence,
            reducedKey: reducedKey,
            renderDescription: {
                renderValue(reducedValue)
            },
            signature: signature,
            symptom: symptom,
            phase: phase,
            timestampNanoseconds: monotonicNanoseconds(),
            attemptIndex: attemptIndex,
            unnormalizedResidual: unnormalizedResidual,
            countsAsInstance: countsAsInstance
        )
        timing.reductionNanoseconds += monotonicNanoseconds() - reductionStart

        if classification.isNewCluster {
            forceCheckpoint = true
            // Faults outlive coverage: a target whose last new edge arrives in under a second can still be classifying new clusters twenty seconds later, and stopping on coverage alone loses them.
            lastNewClusterNanoseconds = monotonicNanoseconds()
            if attemptsAtFirstFault == 0 {
                attemptsAtFirstFault = counts.totalAttempts
            }
        }
        if wasEscape {
            faults.gate.noteEscapeOutcome(symptom: symptom, isNewCluster: classification.isNewCluster)
        }
        if let parentIndex {
            corpus.upgradeFailureBoost(
                atParentIndex: parentIndex,
                isNewCluster: classification.isNewCluster,
                clusterInstanceCount: classification.instanceCount,
                clusterCapReached: classification.capReached
            )
        }
        checkpointIfDue()
    }
}
