//
//  ReductionState+FibreDescent.swift
//  Exhaust
//
//  Created by Chris Kolbu on 25/3/2026.
//

/// Maximum remaining range size for which ``LinearScanEncoder`` is emitted.
let linearScanThreshold = 64

// MARK: - Fibre Descent (Value Minimization)

extension ReductionState {
    /// Fibre descent: minimises the value assignment within the fibre above the current base point.
    ///
    /// Categorically, this is the vertical factor of the cartesian-vertical factorisation — every accepted candidate stays in the same fibre (same trace structure). A ``StructuralFingerprint`` guard detects accidental base changes and rolls them back, enforcing the factorisation boundary. In Bonsai terms, it refines the leaves of the tree: with the branch structure fixed, each leaf value is reduced toward its simplest form. In plain language, it makes the values in the failing test case smaller and simpler without changing how many values there are or how they relate to each other.
    ///
    /// Processes DAG leaf positions first, then sweeps bound-content values at intermediate bind depths from minimum upward (covariant). Returns `true` if any value reduction was committed.
    func runFibreDescent(
        budget: inout Int,
        dependencyGraph: ChoiceDependencyGraph?,
        scopeRange: ClosedRange<Int>? = nil
    ) throws -> Bool {
        phaseTracker.push(.fibreDescent)
        defer { phaseTracker.pop() }
        let subBudget = min(budget, BonsaiScheduler.verificationBudget)
        guard subBudget > 0 else { return false }

        var legBudget = ReductionScheduler.LegBudget(hardCap: subBudget)
        spanCache.invalidate()
        dominance.invalidate()
        var anyAccepted = false

        // Profiling: count coordinates with cached floors at Phase 2 start
        var convergedCount = 0
        var totalValueCount = 0
        for index in 0 ..< sequence.count {
            guard sequence[index].value != nil else { continue }
            totalValueCount += 1
            if convergenceCache.convergedOrigin(at: index) != nil {
                convergedCount += 1
            }
        }
        convergedCoordinatesAtPhaseTwoStart += convergedCount
        totalValueCoordinatesAtPhaseTwoStart += totalValueCount

        // Build converged origins once for all fibre descent calls in this pass.
        // Mid-pass updates (from one encoder's convergence records) must not leak into
        // another encoder's converged origins — the cross-zero skip relies on the
        // converged bound matching the value at which cross-zero was last attempted,
        // which is encoder-specific. A shared mid-pass update would let one
        // encoder's convergence trigger another encoder's cross-zero skip even
        // though cross-zero at that value was never attempted by the second encoder.
        let cachedOrigins = convergenceCache.allEntries

        let suppressZeroValue: Bool = {
            guard let origins = cachedOrigins,
                  origins.isEmpty == false
            else { return false }
            return origins.values.allSatisfy {
                $0.signal == .zeroingDependency
            }
        }()

        // Compute target leaf ranges, optionally filtered to the scope.
        var leafRanges = computeLeafRanges(dependencyGraph: dependencyGraph)
        if let scope = scopeRange {
            leafRanges = leafRanges.filter { scope.overlaps($0) }
        }

        // Capture skeleton fingerprint before fibre descent starts.
        let prePhaseFingerprint = bindIndex.map {
            StructuralFingerprint.from(sequence, bindIndex: $0)
        }

        // Per-leaf-range value minimization pass.
        for leafRange in leafRanges {
            guard legBudget.isExhausted == false else { break }

            // Determine whether this leaf range needs the fingerprint guard. Bound leaves inside
            // non-constant bind regions can cause structural changes; guard fires on first acceptance.
            let isInBound = bindIndex?.isInBoundSubtree(leafRange.lowerBound) ?? false
            let structureChanged = isInBound && hasBind
            let needsFingerprintGuard: Bool
            if structureChanged, let currentBindIndex = bindIndex {
                let isConstant = dependencyGraph?.nodes.contains { node in
                    guard case let .structural(.bindInner(regionIndex: regionIndex)) = node.kind,
                          regionIndex < currentBindIndex.regions.count else { return false }
                    let region = currentBindIndex.regions[regionIndex]
                    return region.boundRange.contains(leafRange.lowerBound)
                        && node.isStructurallyConstant
                } ?? false
                needsFingerprintGuard = isConstant == false
            } else {
                needsFingerprintGuard = false
            }

            var restartLeafRange = false
            repeat {
                restartLeafRange = false

                let leafSpans = extractValueSpans(in: leafRange)
                guard leafSpans.isEmpty == false else { break }

                let floatSpans = leafSpans.filter { span in
                    guard let value = sequence[span.range.lowerBound].value else { return false }
                    return value.choice.tag.isFloatingPoint
                }
                let decoder: SequenceDecoder = isInBound
                    ? .guided(fallbackTree: fallbackTree ?? tree)
                    : .exact()

                let leafContext = ReductionContext(
                    bindIndex: bindIndex,
                    convergedOrigins: cachedOrigins,
                    dependencyGraph: dependencyGraph,
                    filterValidityRates: filterValiditySnapshot
                )
                let activeFingerprint = needsFingerprintGuard ? prePhaseFingerprint : nil

                var firstAcceptedSlot: ReductionScheduler.ValueEncoderSlot?
                for slot in trainOrder {
                    guard legBudget.isExhausted == false else { break }
                    let encoder: (any ComposableEncoder)? = switch slot {
                    case .zeroValue where leafSpans.isEmpty == false && suppressZeroValue == false:
                        zeroValueEncoder
                    case .binarySearchToZero where leafSpans.isEmpty == false:
                        binarySearchToZeroEncoder
                    case .reduceFloat where floatSpans.isEmpty == false:
                        reduceFloatEncoder
                    default:
                        nil
                    }
                    guard let encoder else { continue }
                    if try runComposable(
                        encoder, decoder: decoder, positionRange: leafRange,
                        context: leafContext, structureChanged: structureChanged,
                        budget: &legBudget, fingerprintGuard: activeFingerprint
                    ) {
                        if firstAcceptedSlot == nil { firstAcceptedSlot = slot }
                    }
                }

                // LinearScanEncoder for nonMonotoneGap signals.
                if let origins = cachedOrigins {
                    if try runLinearScans(
                        origins: origins,
                        decoder: decoder,
                        positionRange: leafRange,
                        context: leafContext,
                        structureChanged: structureChanged,
                        budget: &legBudget,
                        fingerprintGuard: activeFingerprint
                    ) {
                        anyAccepted = true
                    }
                }

                if let firstAccepted = firstAcceptedSlot {
                    ReductionScheduler.moveToFront(firstAccepted, in: &trainOrder)
                    anyAccepted = true
                    if needsFingerprintGuard {
                        restartLeafRange = true
                    }
                }
            } while restartLeafRange && legBudget.isExhausted == false
        }

        // Covariant value sweep: reduce bound-content values at intermediate bind depths.
        // DAG leaf positions miss values inside nested bind regions (for example, parent node values in a recursive bind generator like a binary heap). Shallow depths first so that deeper depths reduce in the correct context.
        // vSpans at depth D can include nested bind-inner positions whose reduction changes the inner bound structure, which belongs in base descent. The fingerprintGuard in each runComposable call catches this per-acceptance and rolls back the structural probe while preserving any earlier clean value reductions.
        let maxBindDepth = bindIndex?.maxBindDepth ?? 0
        let fullRange = 0 ... max(0, sequence.count - 1)
        if maxBindDepth >= 1, legBudget.isExhausted == false {
            for depth in stride(from: 1, through: maxBindDepth, by: 1) {
                guard legBudget.isExhausted == false else { break }
                dominance.invalidate()
                let depthDecoderContext = DecoderContext(
                    depth: .specific(depth),
                    bindIndex: bindIndex,
                    fallbackTree: fallbackTree,
                    strictness: .normal
                )
                let depthDecoder = SequenceDecoder.for(depthDecoderContext)
                let depthContext = ReductionContext(
                    bindIndex: bindIndex,
                    convergedOrigins: cachedOrigins,
                    dependencyGraph: dependencyGraph,
                    depthFilter: depth,
                    filterValidityRates: filterValiditySnapshot
                )
                let hasValueSpansAtDepth = spanCache.valueSpans(
                    at: depth, from: sequence, bindIndex: bindIndex
                ).isEmpty == false
                let hasFloatsAtDepth = spanCache.floatSpans(
                    at: depth, from: sequence, bindIndex: bindIndex
                ).isEmpty == false

                var firstAcceptedDepthSlot: ReductionScheduler.ValueEncoderSlot?
                for slot in trainOrder {
                    guard legBudget.isExhausted == false else { break }
                    let encoder: (any ComposableEncoder)? = switch slot {
                    case .zeroValue where hasValueSpansAtDepth && suppressZeroValue == false:
                        zeroValueEncoder
                    case .binarySearchToZero where hasValueSpansAtDepth:
                        binarySearchToZeroEncoder
                    case .reduceFloat where hasFloatsAtDepth:
                        reduceFloatEncoder
                    default:
                        nil
                    }
                    guard let encoder else { continue }
                    if try runComposable(
                        encoder, decoder: depthDecoder, positionRange: fullRange,
                        context: depthContext, structureChanged: hasBind,
                        budget: &legBudget, fingerprintGuard: prePhaseFingerprint
                    ) {
                        if firstAcceptedDepthSlot == nil { firstAcceptedDepthSlot = slot }
                    }
                }

                // LinearScanEncoder for nonMonotoneGap signals.
                if let origins = cachedOrigins {
                    if try runLinearScans(
                        origins: origins,
                        decoder: depthDecoder,
                        positionRange: fullRange,
                        context: depthContext,
                        structureChanged: hasBind,
                        budget: &legBudget,
                        fingerprintGuard: prePhaseFingerprint
                    ) {
                        anyAccepted = true
                    }
                }

                if let firstAccepted = firstAcceptedDepthSlot {
                    ReductionScheduler.moveToFront(firstAccepted, in: &trainOrder)
                    anyAccepted = true
                }
            }
        }

        // Shared decoder context for reorder and redistribution passes.
        let tailDecoderContext = DecoderContext(
            depth: .global,
            bindIndex: bindIndex,
            fallbackTree: fallbackTree,
            strictness: .normal
        )
        let tailDecoder = SequenceDecoder.for(tailDecoderContext)
        let tailContext = ReductionContext(
            bindIndex: bindIndex,
            convergedOrigins: cachedOrigins,
            dependencyGraph: dependencyGraph,
            filterValidityRates: filterValiditySnapshot
        )

        // Shortlex reorder: sort siblings by shortlex key after values settle.
        if legBudget.isExhausted == false {
            if try runComposable(
                shortlexReorderEncoder, decoder: tailDecoder,
                positionRange: fullRange, context: tailContext,
                structureChanged: hasBind, budget: &legBudget
            ) {
                anyAccepted = true
            }
        }

        // Redistribution (once at end of fibre descent).
        if legBudget.isExhausted == false {
            if try runComposable(
                tandemEncoder, decoder: tailDecoder,
                positionRange: fullRange, context: tailContext,
                structureChanged: hasBind, budget: &legBudget
            ) {
                anyAccepted = true
            }
            if try runComposable(
                redistributeEncoder, decoder: tailDecoder,
                positionRange: fullRange, context: tailContext,
                structureChanged: hasBind, budget: &legBudget
            ) {
                anyAccepted = true
            }
        }

        if isInstrumented {
            ExhaustLog.debug(
                category: .reducer,
                event: "bonsai_phase2_complete",
                metadata: [
                    "progress": "\(anyAccepted)",
                    "budget_remaining": "\(budget)",
                ]
            )
        }

        budget -= legBudget.used
        return anyAccepted
    }
}

// MARK: - Helpers

extension ReductionState {
    /// Computes ordered leaf ranges for fibre descent.
    ///
    /// Uses DAG leaf positions when available. For bind-free generators, uses all value spans at depth 0. Leaves inside bind-bound subtrees are ordered first (structural proximity ordering).
    func computeLeafRanges(dependencyGraph: ChoiceDependencyGraph?) -> [ClosedRange<Int>] {
        if let dependencyGraph {
            // Sort: leaves inside bind-bound subtrees first, then by position ascending.
            return dependencyGraph.leafPositions.sorted { lhs, rhs in
                let lhsInBound = bindIndex?.isInBoundSubtree(lhs.lowerBound) ?? false
                let rhsInBound = bindIndex?.isInBoundSubtree(rhs.lowerBound) ?? false
                if lhsInBound != rhsInBound {
                    return lhsInBound
                }
                return lhs.lowerBound < rhs.lowerBound
            }
        }

        // Bind-free: all value spans at depth 0 as a single contiguous range.
        let valueSpans = spanCache.valueSpans(at: 0, from: sequence, bindIndex: bindIndex)
        guard valueSpans.isEmpty == false else { return [] }
        var minPosition = valueSpans[0].range.lowerBound
        var maxPosition = valueSpans[0].range.upperBound
        for span in valueSpans.dropFirst() {
            if span.range.lowerBound < minPosition { minPosition = span.range.lowerBound }
            if span.range.upperBound > maxPosition { maxPosition = span.range.upperBound }
        }
        return [minPosition ... maxPosition]
    }

    /// Extracts value spans within the given position range.
    private func extractValueSpans(in range: ClosedRange<Int>) -> [ChoiceSpan] {
        let allSpans = spanCache.valueSpans(at: 0, from: sequence, bindIndex: bindIndex)
        return allSpans.filter { range.contains($0.range.lowerBound) }
    }

    /// Runs ``LinearScanEncoder`` probes for all `nonMonotoneGap` convergence signals within budget.
    private func runLinearScans(
        origins: [Int: ConvergedOrigin],
        decoder: SequenceDecoder,
        positionRange: ClosedRange<Int>,
        context: ReductionContext,
        structureChanged: Bool,
        budget: inout ReductionScheduler.LegBudget,
        fingerprintGuard: StructuralFingerprint?
    ) throws -> Bool {
        var anyAccepted = false
        for (position, origin) in origins {
            guard budget.isExhausted == false else { break }
            guard case let .nonMonotoneGap(remainingRange) = origin.signal,
                  remainingRange <= linearScanThreshold,
                  remainingRange > 0
            else { continue }
            let scanEncoder = LinearScanEncoder(
                targetPosition: position,
                scanRange: (origin.bound >= UInt64(remainingRange))
                    ? (origin.bound - UInt64(remainingRange)) ... (origin.bound - 1)
                    : 0 ... (origin.bound - 1),
                scanDirection: .upward
            )
            if try runComposable(
                scanEncoder, decoder: decoder, positionRange: positionRange,
                context: context, structureChanged: structureChanged,
                budget: &budget, fingerprintGuard: fingerprintGuard
            ) {
                anyAccepted = true
            }
        }
        return anyAccepted
    }
}
