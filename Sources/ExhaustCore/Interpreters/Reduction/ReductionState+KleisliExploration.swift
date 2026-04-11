//
//  ReductionState+KleisliExploration.swift
//  Exhaust
//
//  Created by Chris Kolbu on 25/3/2026.
//

// MARK: - Kleisli Exploration

extension ReductionState {
    /// Explores cross-level minima via ``KleisliComposition`` along CDG dependency edges.
    ///
    /// Targets the case where Phase 1c's guided lift does not preserve the failure at a reduced bind-inner value, but a specific downstream reduction in the new fibre recovers it. The composition searches both levels jointly — the upstream encoder proposes bind-inner values, the generator lift materializes without property check, and the downstream encoder searches the lifted fibre.
    ///
    /// Uses a checkpoint/rollback pattern: snapshot before exploration, accept only if the net result is shortlex-better than the checkpoint.
    ///
    /// Returns `true` if the exploration found a net improvement.
    func runKleisliExploration(
        budget: inout Int,
        dependencyGraph: ChoiceDependencyGraph?,
        edgeBudgetPolicy: EdgeBudgetPolicy = .fixed(100),
        scopeRange: ClosedRange<Int>? = nil
    ) throws -> Bool {
        phaseTracker.push(.exploration)
        defer { phaseTracker.pop() }
        guard hasBind, let dependencyGraph, let bindSpanIndex = bindIndex else { return false }

        var edges = dependencyGraph.reductionEdges()
        // When scoped, only explore edges whose upstream falls within the scope.
        if let scope = scopeRange {
            edges = edges.filter { scope.overlaps($0.upstreamRange) }
        }
        guard edges.isEmpty == false else {
            if isInstrumented {
                ExhaustLog.debug(
                    category: .reducer,
                    event: "kleisli_exploration_skip",
                    metadata: ["reason": "no_edges"]
                )
            }
            return false
        }

        if isInstrumented {
            ExhaustLog.debug(
                category: .reducer,
                event: "kleisli_exploration_start",
                metadata: [
                    "edges": "\(edges.count)",
                    "seq_len": "\(sequence.count)",
                ]
            )
        }

        let checkpoint = makeSnapshot()
        let acceptancesAtCheckpoint = phaseTracker.counts[.exploration]?.acceptances ?? 0
        let structuralAtCheckpoint = phaseTracker.counts[.exploration]?.structuralAcceptances ?? 0
        var anyAccepted = false
        var kleisliProbes = 0
        var kleisliMaterializations = 0

        let compositionEdges = Self.compositionDescriptors(
            edges: edges,
            gen: gen,
            sequence: sequence,
            tree: tree,
            fallbackTree: fallbackTree
        )

        // Discovery lifts: predictFibreSizeAtTarget materializes once per structurally constant edge.
        if collectStats {
            let discoveryLifts = compositionEdges.count { $0.edge.isStructurallyConstant }
            kleisliMaterializations += discoveryLifts
        }

        for var compositionEdge in compositionEdges {
            guard budget > 0 else { break }
            compositionEdgesAttempted += 1

            let edge = compositionEdge.edge
            let prediction = compositionEdge.prediction

            // Skip structurally constant edges where the prior cycle's downstream
            // exhaustively searched the fibre and found no failure at this upstream value.
            if edge.isStructurallyConstant,
               let observation = edgeObservations[edge.regionIndex],
               observation.signal == .exhaustedClean,
               let currentUpstreamValue = sequence[
                   edge.upstreamRange.lowerBound
               ].value?.choice.bitPattern64,
               observation.upstreamValue == currentUpstreamValue
            {
                continue
            }

            // Run via manual loop.
            let edgeSubBudget: Int = {
                switch edgeBudgetPolicy {
                case let .fixed(cap):
                    return min(budget, cap)
                case .adaptive:
                    let baseBudget = 100
                    guard let observation = edgeObservations[edge.regionIndex] else {
                        return min(budget, baseBudget)
                    }
                    switch observation.signal {
                    case .exhaustedWithFailure:
                        // Productive edge — increase budget by 50%.
                        return min(budget, baseBudget + baseBudget / 2)
                    case .exhaustedClean:
                        // Clean edge not caught by the skip above (data-dependent edge, or
                        // upstream value changed). Reduce budget by 50%.
                        return min(budget, baseBudget / 2)
                    case .bail:
                        // Bail — DownstreamPick should prevent this, but if it persists,
                        // reduce budget.
                        return min(budget, baseBudget / 2)
                    }
                }
            }()
            var legBudget = ReductionScheduler.LegBudget(hardCap: edgeSubBudget)

            let context = ReductionContext(
                bindIndex: bindSpanIndex,
                convergedOrigins: convergenceCache.allEntries,
                dependencyGraph: dependencyGraph
            )
            // Do not pass converged origins to the composition. The convergence
            // cache records floors established by the standalone pipeline — values
            // below which the property passes WITHOUT downstream fibre search.
            // The composition's purpose is to re-explore those values WITH
            // downstream search. Passing the cache would tell the upstream encoder
            // its current value is already at the floor, producing zero probes.
            compositionEdge.composition.start(
                sequence: sequence,
                tree: tree,
                positionRange: 0 ... max(0, sequence.count - 1),
                context: context
            )

            var lastAccepted = false
            var anyAcceptedThisEdge = false
            while true {
                // Warm-start validation: before the composition advances to the
                // next upstream probe and initializes the downstream, validate any
                // pending convergence transfer from the previous downstream.
                if let pending = compositionEdge.composition.pendingTransferOrigins,
                   let delta = compositionEdge.composition.upstreamDelta, delta == 1
                {
                    // Adjacent upstream values — validate each origin at floor - 1.
                    convergenceTransfersAttempted += 1
                    var allValid = true
                    for (index, origin) in pending {
                        guard index < sequence.count,
                              let value = sequence[index].value,
                              let range = value.validRange,
                              origin.bound > range.lowerBound
                        else { continue }

                        let probeBitPattern = origin.bound - 1
                        var candidate = sequence
                        candidate[index] = .value(.init(
                            choice: ChoiceValue(
                                value.choice.tag.makeConvertible(bitPattern64: probeBitPattern),
                                tag: value.choice.tag
                            ),
                            validRange: value.validRange,
                            isRangeExplicit: value.isRangeExplicit
                        ))
                        legBudget.recordMaterialization()
                        phaseTracker.recordInvocation()

                        let validationDecoder = SequenceDecoder.exact()
                        if let result = try validationDecoder.decode(
                            candidate: candidate,
                            gen: gen,
                            tree: tree,
                            originalSequence: sequence,
                            property: property
                        ), result.sequence.shortLexPrecedes(sequence) {
                            // Property fails at floor - 1: floor is stale.
                            // Discard ALL pending origins and cold-start.
                            allValid = false
                            accept(result, structureChanged: false)
                            anyAccepted = true
                            break
                        }
                    }
                    if allValid {
                        convergenceTransfersValidated += 1
                    } else {
                        convergenceTransfersStale += 1
                    }
                    compositionEdge.composition.setValidatedOrigins(allValid ? pending : nil)
                } else {
                    // First probe, delta > 1, or no pending origins: cold-start.
                    compositionEdge.composition.setValidatedOrigins(nil)
                }

                guard let probe = compositionEdge.composition.nextProbe(
                    lastAccepted: lastAccepted
                ) else {
                    break
                }
                guard legBudget.isExhausted == false else { break }
                if collectStats { kleisliProbes += 1 }
                legBudget.recordMaterialization()
                phaseTracker.recordInvocation()

                let decoder = SequenceDecoder.exact()
                if let result = try decoder.decode(
                    candidate: probe,
                    gen: gen,
                    tree: tree,
                    originalSequence: sequence,
                    property: property
                ) {
                    if result.sequence.shortLexPrecedes(sequence) {
                        accept(result, structureChanged: true)
                        lastAccepted = true
                        anyAccepted = true
                        anyAcceptedThisEdge = true

                        if isInstrumented {
                            ExhaustLog.debug(
                                category: .reducer,
                                event: "kleisli_exploration_accepted",
                                metadata: [
                                    "region": "\(edge.regionIndex)",
                                    "seq_len": "\(sequence.count)",
                                ]
                            )
                        }
                    } else {
                        lastAccepted = false
                    }
                } else {
                    lastAccepted = false
                }
            }

            // Track futile compositions (zero accepted probes for this edge)
            if legBudget.used > 0, anyAcceptedThisEdge == false {
                futileCompositions += 1
            }

            // Harvest fibre telemetry from the composition's downstream encoder.
            if collectStats {
                let comp = compositionEdge.composition
                fibreExceededExhaustiveThreshold += comp.fibrePairwiseStarts
                pairwiseOnExhaustibleFibre += comp.fibreExhaustiveStarts
                fibreZeroValueStarts += comp.fibreZeroValueStarts

                // Compare prediction against ground truth.
                // The prediction uses the current sequence; the ground truth uses the lifted sequences.
                // "Correct" means the predicted mode matches the MAJORITY of actual downstream starts.
                let actualMajorityMode: FibrePrediction.Mode = {
                    if comp.fibreExhaustiveStarts >= comp.fibrePairwiseStarts,
                       comp.fibreExhaustiveStarts >= comp.fibreZeroValueStarts
                    {
                        return .exhaustive
                    }
                    if comp.fibrePairwiseStarts >= comp.fibreZeroValueStarts {
                        return .pairwise
                    }
                    return .tooLarge
                }()

                let totalStarts = comp.fibreExhaustiveStarts
                    + comp.fibrePairwiseStarts
                    + comp.fibreZeroValueStarts
                if totalStarts > 0 {
                    if prediction.predictedMode == actualMajorityMode {
                        fibrePredictionCorrect += 1
                    } else {
                        fibrePredictionWrong += 1
                    }
                }
            }

            // Log prediction vs ground truth for encoder selection accuracy measurement.
            if isInstrumented {
                let actualExhaustive = compositionEdge.composition.fibreExhaustiveStarts
                let actualPairwise = compositionEdge.composition.fibrePairwiseStarts
                let actualBail = compositionEdge.composition.fibreZeroValueStarts
                let predictionLabel = switch prediction.predictedMode {
                case .exhaustive: "exhaustive"
                case .pairwise: "pairwise"
                case .tooLarge: "too_large"
                }
                ExhaustLog.debug(
                    category: .reducer,
                    event: "fibre_prediction",
                    metadata: [
                        "region": "\(edge.regionIndex)",
                        "predicted_mode": predictionLabel,
                        "predicted_size": "\(prediction.predictedSize)",
                        "predicted_params": "\(prediction.parameterCount)",
                        "actual_exhaustive": "\(actualExhaustive)",
                        "actual_pairwise": "\(actualPairwise)",
                        "actual_bail": "\(actualBail)",
                        "max_fibre": "\(compositionEdge.composition.maxObservedFibreSize)",
                    ]
                )
            }

            // Record per-edge observation for cross-cycle factory decisions.
            let totalDownstreamStarts = compositionEdge.composition.fibreExhaustiveStarts
                + compositionEdge.composition.fibrePairwiseStarts
                + compositionEdge.composition.fibreZeroValueStarts
            let edgeSignal: FibreSignal = {
                if totalDownstreamStarts == 0 {
                    return .bail(paramCount: edge.downstreamRange.count)
                }
                return anyAcceptedThisEdge ? .exhaustedWithFailure : .exhaustedClean
            }()
            if let upstreamValue = compositionEdge.composition.previousUpstreamBitPattern {
                edgeObservations[edge.regionIndex] = EdgeObservation(
                    signal: edgeSignal,
                    upstreamValue: upstreamValue
                )
            }
            if collectStats {
                switch edgeSignal {
                case .exhaustedClean: fibreExhaustedCleanCount += 1
                case .exhaustedWithFailure: fibreExhaustedWithFailureCount += 1
                case .bail: fibreBailCount += 1
                }
            }

            budget -= legBudget.used
            if collectStats {
                // legBudget.used counts property-checked materializations (downstream probes). upstreamProbesUsed counts GeneratorLift materializations that do NOT check the property — one per upstream probe.
                kleisliMaterializations += legBudget.used
                    + compositionEdge.composition.upstreamProbesUsed
            }
        }

        if collectStats {
            encoderProbes[.kleisliComposition, default: 0] += kleisliProbes
            totalMaterializations += kleisliMaterializations
        }

        // Pipeline acceptance: net improvement check.
        if anyAccepted, sequence.shortLexPrecedes(checkpoint.sequence) {
            bestSequence = sequence
            bestOutput = output

            if isInstrumented {
                ExhaustLog.debug(
                    category: .reducer,
                    event: "kleisli_exploration_complete",
                    metadata: [
                        "accepted": "true",
                        "seq_len": "\(sequence.count)",
                    ]
                )
            }

            return true
        }

        // Rollback: net result was not an improvement. Revert acceptances but keep invocations.
        phaseTracker.restoreAcceptances(
            for: .exploration,
            acceptances: acceptancesAtCheckpoint,
            structuralAcceptances: structuralAtCheckpoint
        )
        restoreSnapshot(checkpoint)
        return false
    }
}

// MARK: - Composition Descriptors

/// A composition edge paired with its fibre prediction, ready for execution.
struct CompositionEdge<Output> {
    var composition: KleisliComposition<Output>
    let prediction: FibrePrediction
    let edge: ReductionEdge
}

/// Predicts the downstream fibre size for a CDG edge from the current sequence state.
///
/// Walks value positions in the downstream range, reads their domain sizes from ``validRange``, and returns the product. This is the same computation ``FibreCoveringEncoder`` performs at ``ComposableEncoder/start(sequence:tree:positionRange:context:)`` time — but computed on the CURRENT sequence before the upstream mutation, not on the lifted sequence after it.
///
/// The prediction is accurate when the downstream domains are independent of the upstream value (structurally constant edges). For data-dependent edges, the actual fibre size after lift may differ.
struct FibrePrediction {
    /// Product of domain sizes across downstream value positions.
    let predictedSize: UInt64
    /// Number of value parameters in the downstream range.
    let parameterCount: Int
    /// Predicted encoder mode based on thresholds.
    let predictedMode: Mode

    enum Mode: Equatable {
        case exhaustive // predictedSize <= 64
        case pairwise // predictedSize > 64, parameterCount <= 20
        case tooLarge // parameterCount > 20 or overflow
    }
}

extension ReductionState {
    /// Builds composition edges from CDG reduction edges, ordered by predicted fibre size.
    ///
    /// Each edge gets a discovery lift at the upstream's reduction target to predict the downstream fibre size. Edges predicted as too large (> 20 parameters, downstream encoder would bail with zero probes) are excluded. Remaining edges are ordered by ascending predicted fibre size — cheaper edges first.
    static func compositionDescriptors(
        edges: [ReductionEdge],
        gen: FreerMonad<ReflectiveOperation, Output>,
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        fallbackTree: ChoiceTree?
    ) -> [CompositionEdge<Output>] {
        var result = [CompositionEdge<Output>]()
        result.reserveCapacity(edges.count)

        for edge in edges {
            let prediction: FibrePrediction

            // Structurally constant edges: the fibre shape is invariant under upstream
            // value changes. The discovery lift at the target sees the same fibre as every
            // other upstream value — the prediction is exact. Select the downstream encoder
            // at factory time.
            //
            // Data-dependent edges: the fibre varies with each upstream candidate. The
            // discovery lift sees the target's fibre (typically the smallest). Don't commit
            // to a downstream encoder based on this — let FibreCoveringEncoder inspect
            // the actual fibre at start() time and select exhaustive or pairwise.
            if edge.isStructurallyConstant {
                prediction = predictFibreSizeAtTarget(
                    sequence: sequence,
                    edge: edge,
                    gen: gen,
                    tree: tree,
                    fallbackTree: fallbackTree
                )
                // For constant edges, the prediction is exact. Skip if tooLarge.
                if prediction.predictedMode == .tooLarge {
                    continue
                }
            } else {
                // For data-dependent edges, use the current-sequence prediction for ordering
                // only. Don't skip — the actual fibre may be smaller at some upstream values.
                prediction = predictFibreSize(
                    sequence: sequence,
                    downstreamRange: edge.downstreamRange
                )
            }

            // Constant edges: FibreCoveringEncoder (prediction is exact, fibre won't change).
            // Data-dependent edges: DownstreamPick selects at runtime based on actual fibre.
            let downstream: any ComposableEncoder = {
                guard edge.isStructurallyConstant == false else {
                    return FibreCoveringEncoder()
                }
                return DownstreamPick(alternatives: [
                    // Exhaustive: small fibres (<= 64 combinations).
                    .init(
                        encoder: FibreCoveringEncoder(),
                        predicate: { totalSpace, _ in
                            totalSpace <= FibreCoveringEncoder.exhaustiveThreshold
                        }
                    ),
                    // Pairwise: medium fibres (2–20 parameters).
                    .init(
                        encoder: FibreCoveringEncoder(),
                        predicate: { _, paramCount in
                            paramCount >= 2 && paramCount <= 20
                        }
                    ),
                    // Binary search: single-parameter fibres too large for
                    // exhaustive. Searches each coordinate toward its
                    // semantic simplest. In a Kleisli downstream context the
                    // upstream improvement dominates shortlex, so even
                    // partial convergence helps.
                    .init(
                        encoder: BinarySearchToSemanticSimplestEncoder(),
                        predicate: { _, paramCount in paramCount == 1 }
                    ),
                    // Zero-value: large fibres (> 20 params or overflow).
                    .init(
                        encoder: ZeroValueEncoder(),
                        predicate: { _, _ in true }
                    ),
                ])
            }()

            let composition = KleisliComposition(
                upstream: BinarySearchToSemanticSimplestEncoder(),
                downstream: downstream,
                lift: GeneratorLift(gen: gen, mode: .guided(fallbackTree: fallbackTree ?? tree)),
                upstreamRange: edge.upstreamRange,
                downstreamRange: edge.downstreamRange
            )

            result.append(CompositionEdge(
                composition: composition,
                prediction: prediction,
                edge: edge
            ))
        }

        // Order by leverage / requiredBudget (descending). Higher score = more structural
        // impact per probe. Leverage is the downstream range size; required budget is the
        // predicted fibre size (capped at the covering budget for pairwise).
        result.sort { lhs, rhs in
            let coveringCap = UInt64(FibreCoveringEncoder.coveringBudget)
            let lhsBudget = max(1, min(lhs.prediction.predictedSize, coveringCap))
            let rhsBudget = max(1, min(rhs.prediction.predictedSize, coveringCap))
            let lhsLeverage = UInt64(lhs.edge.downstreamRange.count)
            let rhsLeverage = UInt64(rhs.edge.downstreamRange.count)
            // leverage / budget — higher is better. Cross-multiply to avoid division.
            return lhsLeverage * rhsBudget > rhsLeverage * lhsBudget
        }

        return result
    }

    // MARK: - Fibre size prediction

    /// Predicts downstream fibre size from the current sequence state.
    static func predictFibreSize(
        sequence: ChoiceSequence,
        downstreamRange: ClosedRange<Int>
    ) -> FibrePrediction {
        var parameterCount = 0
        var product: UInt64 = 1
        var overflowed = false

        for index in downstreamRange {
            guard index < sequence.count else { break }
            guard let value = sequence[index].value,
                  let validRange = value.validRange
            else { continue }

            parameterCount += 1
            let domainSize = validRange.upperBound - validRange.lowerBound + 1
            let (result, overflow) = product.multipliedReportingOverflow(by: domainSize)
            if overflow || result > UInt64.max / 2 {
                overflowed = true
                break
            }
            product = result
        }

        let predictedSize = overflowed ? UInt64.max : product
        let mode: FibrePrediction.Mode = {
            if overflowed || parameterCount > 20 { return .tooLarge }
            if predictedSize <= FibreCoveringEncoder.exhaustiveThreshold { return .exhaustive }
            return .pairwise
        }()

        return FibrePrediction(
            predictedSize: predictedSize,
            parameterCount: parameterCount,
            predictedMode: mode
        )
    }

    /// Predicts downstream fibre size at the upstream's reduction target via a discovery lift.
    ///
    /// Sets the upstream bind-inner value to its reduction target (range minimum or semantic simplest), materialises the generator to produce a fresh downstream sequence, then reads the fibre size from the lifted result. This is one materialisation — the "discovery budget" from the planning document.
    ///
    /// Returns the naive prediction (from the current sequence) if the discovery lift fails.
    static func predictFibreSizeAtTarget(
        sequence: ChoiceSequence,
        edge: ReductionEdge,
        gen: FreerMonad<ReflectiveOperation, Output>,
        tree: ChoiceTree,
        fallbackTree: ChoiceTree?
    ) -> FibrePrediction {
        // Read the upstream value and compute its reduction target.
        let upstreamIndex = edge.upstreamRange.lowerBound
        guard upstreamIndex < sequence.count,
              let upstreamValue = sequence[upstreamIndex].value
        else {
            return predictFibreSize(sequence: sequence, downstreamRange: edge.downstreamRange)
        }

        let isWithinRecordedRange =
            upstreamValue.isRangeExplicit
                && upstreamValue.choice.fits(in: upstreamValue.validRange)
        let targetBitPattern = isWithinRecordedRange
            ? upstreamValue.choice.reductionTarget(in: upstreamValue.validRange)
            : upstreamValue.choice.semanticSimplest.bitPattern64

        // If the upstream is already at its target, the current-sequence prediction is exact.
        if targetBitPattern == upstreamValue.choice.bitPattern64 {
            return predictFibreSize(sequence: sequence, downstreamRange: edge.downstreamRange)
        }

        // Build a modified sequence with the upstream set to its target.
        var modified = sequence
        modified[upstreamIndex] = .value(.init(
            choice: ChoiceValue(
                upstreamValue.choice.tag.makeConvertible(bitPattern64: targetBitPattern),
                tag: upstreamValue.choice.tag
            ),
            validRange: upstreamValue.validRange,
            isRangeExplicit: upstreamValue.isRangeExplicit
        ))

        // Discovery lift: materialise at the target upstream value.
        let liftResult = Materializer.materialize(
            gen,
            prefix: modified,
            mode: .exact,
            fallbackTree: fallbackTree ?? tree
        )

        switch liftResult {
        case let .success(_, freshTree, _):
            let freshSequence = ChoiceSequence(freshTree)
            // Read the fibre size from the lifted sequence.
            // The downstream range may shift in the lifted sequence (structural changes).
            // Use the edge's downstream range clamped to the fresh sequence length.
            let clampedUpperBound = min(
                edge.downstreamRange.upperBound,
                max(0, freshSequence.count - 1)
            )
            let clampedRange = edge.downstreamRange.lowerBound ... clampedUpperBound
            return predictFibreSize(sequence: freshSequence, downstreamRange: clampedRange)
        case .rejected(_), .failed:
            // Discovery lift failed (target value out of range or materialisation error).
            // Fall back to the naive prediction from the current sequence.
            return predictFibreSize(sequence: sequence, downstreamRange: edge.downstreamRange)
        }
    }
}
