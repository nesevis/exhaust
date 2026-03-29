/// Self-contained reduction pass for a single topological CDG level.
///
/// Combines structural simplification, value minimization, Kleisli exploration, and redistribution in a single method. Unlike the per-phase approach (where fibre descent, exploration, and redistribution are separate scheduler phases), this method runs all stages in sequence for one CDG level, using depth-aware span extraction directly.
///
/// For bind-inner levels, `depthFilter` restricts value extraction to the correct bind depth. For branch-selector levels, `depthFilter` is nil and value extraction uses the scope range with the exclusion set. The covariant sweep is not used — the outer level walk provides depth iteration.
extension ReductionState {
  /// Runs a complete reduction sub-cycle for one topological CDG level.
  ///
  /// - Parameters:
  ///   - budget: Maximum property invocations for this level.
  ///   - dag: The current choice dependency graph.
  ///   - scopeRange: Position range for this level's nodes.
  ///   - depthFilter: Bind depth to extract value spans at, or nil for branch-selector levels.
  ///   - exclusionRanges: Ranges owned by deeper-level CDG nodes to exclude from span extraction.
  /// - Returns: `true` if any probe was accepted.
  func runLevelReduction(
    budget: inout Int,
    dag: ChoiceDependencyGraph?,
    scopeRange: ClosedRange<Int>,
    depthFilter: Int?,
    exclusionRanges: [ClosedRange<Int>]? = nil
  ) throws -> Bool {
    phaseTracker.push(.levelReduction)
    defer { phaseTracker.pop() }

    let subBudget = min(budget, BonsaiScheduler.verificationBudget)
    guard subBudget > 0 else { return false }
    var legBudget = ReductionScheduler.LegBudget(hardCap: subBudget)
    spanCache.invalidate()
    dominance.invalidate()
    var anyAccepted = false

    // Capture structural fingerprint for rollback guard.
    let prePhaseFingerprint = bindIndex.map {
      StructuralFingerprint.from(sequence, bindIndex: $0)
    }

    // Build convergence origins once for this pass.
    let cachedOrigins = convergenceCache.allEntries

    // MARK: 1. Branch simplification (structural, scoped to this level)

    let branchDecoderContext = DecoderContext(
      depth: .specific(0),
      bindIndex: bindIndex,
      fallbackTree: fallbackTree,
      strictness: .relaxed,
      materializePicks: true
    )
    let branchDecoder = SequenceDecoder.for(branchDecoderContext)
    if branchTreeDirty {
      if case let .success(_, freshTree, _) = ReductionMaterializer.materialize(
        gen, prefix: sequence, mode: .exact, fallbackTree: fallbackTree,
        materializePicks: true
      ) {
        tree = freshTree
      }
      branchTreeDirty = false
    }
    let branchContext = ReductionContext(bindIndex: bindIndex)
    for encoder in [promoteBranchesEncoder, pivotBranchesEncoder, swapSiblingsEncoder] as [any ComposableEncoder] {
      guard legBudget.isExhausted == false else { break }
      if try runComposable(
        encoder, decoder: branchDecoder,
        positionRange: scopeRange, context: branchContext,
        structureChanged: true, budget: &legBudget
      ) {
        anyAccepted = true
      }
    }

    // MARK: 2. Value minimization (depth-aware)

    let targetDepth = depthFilter ?? 0
    let valueDecoderContext = DecoderContext(
      depth: .specific(targetDepth),
      bindIndex: bindIndex,
      fallbackTree: fallbackTree,
      strictness: .normal
    )
    let valueDecoder = SequenceDecoder.for(valueDecoderContext)
    let valueContext = ReductionContext(
      bindIndex: bindIndex,
      convergedOrigins: cachedOrigins,
      dag: dag,
      depthFilter: depthFilter
    )

    // Extract value spans at the target depth within the scope.
    var valueSpans = spanCache.valueSpans(
      at: targetDepth, from: sequence, bindIndex: bindIndex
    ).filter { scopeRange.contains($0.range.lowerBound) }
    if let excluded = exclusionRanges {
      valueSpans = ChoiceDependencyGraph.applyExclusion(
        spans: valueSpans, excluding: excluded
      )
    }

    let suppressZeroValue: Bool = {
      guard let origins = cachedOrigins, origins.isEmpty == false else { return false }
      return origins.values.allSatisfy { $0.signal == .zeroingDependency }
    }()

    let hasValueSpans = valueSpans.isEmpty == false
    let hasFloatSpans = valueSpans.contains { span in
      guard let value = sequence[span.range.lowerBound].value else { return false }
      return value.choice.tag.isFloatingPoint
    }

    // Run value encoders on the extracted spans.
    var firstAcceptedSlot: ReductionScheduler.ValueEncoderSlot?
    for slot in trainOrder {
      guard legBudget.isExhausted == false else { break }
      let encoder: (any ComposableEncoder)? = switch slot {
      case .zeroValue where hasValueSpans && suppressZeroValue == false:
        zeroValueEncoder
      case .binarySearchToZero where hasValueSpans:
        binarySearchToZeroEncoder
      case .binarySearchToTarget where hasValueSpans:
        binarySearchToTargetEncoder
      case .reduceFloat where hasFloatSpans:
        reduceFloatEncoder
      default:
        nil
      }
      guard let encoder else { continue }
      if try runComposable(
        encoder, decoder: valueDecoder, positionRange: scopeRange,
        context: valueContext, structureChanged: hasBind,
        budget: &legBudget, fingerprintGuard: prePhaseFingerprint
      ) {
        if firstAcceptedSlot == nil { firstAcceptedSlot = slot }
      }
    }

    // LinearScan for nonMonotoneGap signals.
    if let origins = cachedOrigins {
      for (position, origin) in origins {
        guard legBudget.isExhausted == false else { break }
        guard scopeRange.contains(position) else { continue }
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
          scanEncoder, decoder: valueDecoder, positionRange: scopeRange,
          context: valueContext, structureChanged: hasBind,
          budget: &legBudget, fingerprintGuard: prePhaseFingerprint
        ) {
          anyAccepted = true
        }
      }
    }

    if let firstAccepted = firstAcceptedSlot {
      ReductionScheduler.moveToFront(firstAccepted, in: &trainOrder)
      anyAccepted = true
    }

    // MARK: 3. Kleisli exploration (scoped to edges at this level)

    if legBudget.isExhausted == false {
      var explorationBudget = legBudget.hardCap - legBudget.used
      if try runKleisliExploration(
        budget: &explorationBudget,
        dag: dag,
        edgeBudgetPolicy: .adaptive,
        scopeRange: scopeRange
      ) {
        anyAccepted = true
      }
    }

    // MARK: 4. Redistribution (scoped)

    if legBudget.isExhausted == false {
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
        dag: dag,
        depthFilter: depthFilter
      )
      if try runComposable(
        tandemEncoder, decoder: tailDecoder,
        positionRange: scopeRange, context: tailContext,
        structureChanged: hasBind, budget: &legBudget
      ) {
        anyAccepted = true
      }
      if try runComposable(
        redistributeEncoder, decoder: tailDecoder,
        positionRange: scopeRange, context: tailContext,
        structureChanged: hasBind, budget: &legBudget
      ) {
        anyAccepted = true
      }
    }

    budget -= legBudget.used
    return anyAccepted
  }
}
