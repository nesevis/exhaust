// MARK: - Branch Handlers

extension Materializer {
    // MARK: - pick (with materialized alternatives)

    /// Selects a branch by reading the branch index from the cursor, then materializes the selected branch's generator.
    ///
    /// In exact mode the cursor must supply a valid branch index or the handler rejects. In guided mode the handler tries the cursor, then the fallback tree's selected branch, then weighted random selection. When ``Context/materializePicks`` is set, non-selected branches are also materialized in minimize mode to populate the ``ChoiceTree`` with shortlex-simplest content for screening analysis.
    @inline(__always)
    static func handlePick(
        _ choices: ContiguousArray<ReflectiveOperation.PickTuple>,
        totalWeight: UInt64,
        continuation: (Any) throws -> AnyGenerator,
        inputValue: Any,
        context: inout Context,
        calleeFallback: ChoiceTree? = nil,
        continuationFallback: ChoiceTree? = nil
    ) throws -> (Any, ChoiceTree)? {
        let branchCount = UInt64(choices.count)
        // Guided resolution must preserve the PRNG stream even when alternatives are omitted. Exact resolution never draws from that stream, so its jump seed is observable only when alternatives consume it.
        let jumpSeed = context.mode == .exact && context.materializePicks == false ? 0 : context.prng.next()

        let fallbackBranch = selectedFallbackBranch(in: calleeFallback)

        let selectedChoice: ReflectiveOperation.PickTuple?
        switch context.mode {
            case .exact:
                guard let prefixBranch = context.cursor.tryConsumeBranch() else {
                    throw RejectionError()
                }
                context.record(.prefix)
                let exactIndex = Int(prefixBranch.id)
                selectedChoice = exactIndex < choices.count ? choices[exactIndex] : nil
                if let observePrefixPick = context.observePrefixPick, exactIndex < choices.count {
                    observePrefixPick(PrefixPickObservation(
                        branchIndex: context.cursor.position - 1,
                        choices: choices,
                        selectedIndex: exactIndex
                    ))
                }

            case .guided:
                switch (context.cursor.tryConsumeBranch(), fallbackBranch) {
                    case let (prefixBranch?, _):
                        context.record(.prefix)
                        let guidedIndex = Int(prefixBranch.id)
                        selectedChoice = guidedIndex < choices.count ? choices[guidedIndex] : nil
                    case let (nil, fallbackBranch?):
                        context.record(.fallbackTree)
                        let fallbackIndex = Int(fallbackBranch.id)
                        selectedChoice = fallbackIndex < choices.count ? choices[fallbackIndex] : nil
                    case (nil, nil):
                        context.record(.prng)
                        selectedChoice = WeightedPickSelection.draw(
                            from: choices,
                            totalWeight: totalWeight,
                            using: &context.prng
                        )
                }

            case .generate:
                context.record(.prng)
                selectedChoice = WeightedPickSelection.draw(
                    from: choices,
                    totalWeight: totalWeight,
                    using: &context.prng
                )

            case .minimize:
                // Minimization chooses an arm by policy rather than replaying a selector.
                context.record(.unknown)
                selectedChoice = choices.first
        }

        guard let selectedChoice else {
            return nil
        }

        let (branchBodyFallback, branchContinuationFallback) = decomposeNonGroupFallback(
            fallbackBranch?.choice
        )

        if context.skipTree {
            // Flat emission mirrors flatten's selected-branch group: group open, branch marker, branch body plus continuation (pair-grouped by runContinuation when the continuation is non-pure), group close.
            context.emitFlat(.group(true))
            context.emitFlat(.branch(.init(
                id: selectedChoice.id,
                branchCount: branchCount,
                fingerprint: choices[0].fingerprint
            )))
            let branchBodyStart = context.flatCount
            guard let (result, _) = try generateRecursive(
                selectedChoice.generator,
                with: inputValue,
                context: &context,
                fallbackTree: branchBodyFallback
            ) else {
                return nil
            }
            guard let continued = try runContinuation(
                result: result,
                calleeChoiceTree: .just,
                calleeStart: branchBodyStart,
                continuation: continuation,
                inputValue: inputValue,
                context: &context,
                continuationFallback: branchContinuationFallback ?? continuationFallback
            ) else {
                return nil
            }
            context.emitFlat(.group(false))
            return continued
        }

        let fingerprint = choices[0].fingerprint
        guard context.materializePicks else {
            let branchBodyStart = context.flatCount
            guard let (result, branchTree) = try generateRecursive(
                selectedChoice.generator,
                with: inputValue,
                context: &context,
                fallbackTree: branchBodyFallback
            ) else {
                return nil
            }

            guard let (continuationValue, continuationTree) = try runContinuation(
                result: result,
                calleeChoiceTree: branchTree,
                calleeStart: branchBodyStart,
                continuation: continuation,
                inputValue: inputValue,
                context: &context,
                continuationFallback: branchContinuationFallback ?? continuationFallback
            ) else {
                return nil
            }

            return (continuationValue, .group([.branch(
                fingerprint: fingerprint,
                weight: selectedChoice.weight,
                id: selectedChoice.id,
                branchCount: branchCount,
                choice: continuationTree,
                isSelected: true
            )]))
        }

        var branches = [ChoiceTree]()
        branches.reserveCapacity(choices.count)
        var finalValue: Any?
        let selectedIndex = Int(selectedChoice.id)

        var choiceIndex = 0
        while choiceIndex < choices.count {
            let choice = choices[choiceIndex]

            if choiceIndex == selectedIndex {
                let branchBodyStart = context.flatCount
                guard let (result, branchTree) = try generateRecursive(
                    choice.generator,
                    with: inputValue,
                    context: &context,
                    fallbackTree: branchBodyFallback
                ) else {
                    return nil
                }

                guard let (continuationValue, continuationTree) = try runContinuation(
                    result: result,
                    calleeChoiceTree: branchTree,
                    calleeStart: branchBodyStart,
                    continuation: continuation,
                    inputValue: inputValue,
                    context: &context,
                    continuationFallback: branchContinuationFallback ?? continuationFallback
                ) else {
                    return nil
                }

                finalValue = continuationValue
                branches.append(.branch(
                    fingerprint: fingerprint,
                    weight: choice.weight,
                    id: choice.id,
                    branchCount: branchCount,
                    choice: continuationTree,
                    isSelected: true
                ))
            } else if let branch = try materializeUnselectedBranch(
                choice,
                fingerprint: fingerprint,
                branchCount: branchCount,
                jumpSeed: jumpSeed,
                continuation: continuation,
                inputValue: inputValue,
                size: context.size
            ) {
                branches.append(branch)
            }
            choiceIndex += 1
        }

        guard let value = finalValue else {
            return nil
        }
        return (value, .group(branches))
    }

    /// Unwraps the bind used by recursive picks before looking for the selected fallback arm.
    private static func selectedFallbackBranch(in tree: ChoiceTree?) -> BranchData? {
        let fallback: ChoiceTree? = switch tree {
            case let .bind(_, _, bound):
                bound
            default:
                tree
        }
        guard let fallback,
              case let .group(children, _, _) = fallback,
              case let .branch(branch) = children.first(where: \.isSelected),
              branch.isSelected
        else {
            return nil
        }
        return branch
    }

    /// Materializes an unselected pick branch in minimize mode, or returns nil when the branch cannot produce a value.
    ///
    /// Minimizing produces the shortlex-simplest content: values use their reduction target (semantic zero when in range), nested picks select the first branch, and sequence lengths minimize, so pivot candidates start from a minimal baseline. The PRNG is only a fallback for operations without minimize-specific handling (filters, recursive unfolds).
    @inline(__always)
    private static func materializeUnselectedBranch(
        _ choice: ReflectiveOperation.PickTuple,
        fingerprint: UInt64,
        branchCount: UInt64,
        jumpSeed: UInt64,
        continuation: (Any) throws -> AnyGenerator,
        inputValue: Any,
        size: UInt64
    ) throws -> ChoiceTree? {
        var branchContext = Context(
            cursor: Cursor.empty,
            prng: Xoshiro256(seed: jumpSeed),
            mode: .minimize,
            size: size
        )
        guard let (result, branchTree) = try generateRecursive(
            choice.generator,
            with: inputValue,
            context: &branchContext,
            fallbackTree: nil
        ),
            let (_, continuationTree) = try runContinuation(
                result: result,
                calleeChoiceTree: branchTree,
                calleeStart: 0,
                continuation: continuation,
                inputValue: inputValue,
                context: &branchContext,
                continuationFallback: nil
            )
        else {
            return nil
        }
        return .branch(
            fingerprint: fingerprint,
            weight: choice.weight,
            id: choice.id,
            branchCount: branchCount,
            choice: continuationTree
        )
    }

    // MARK: - backtrack

    /// Materializes a backtrack pick, auditioning its arms in the manner each mode allows.
    ///
    /// The first arm comes from the prefix or fallback where the mode reads them, exactly as for a committed pick. What differs is a nil arm result: `.exact` rejects the candidate, because the recorded arm no longer reproduces; `.guided` and `.generate` roll the arm's reads and emissions back and draw again among the arms not yet tried; `.minimize` tries the arms in declaration order so the node minimizes to its lowest producing arm. Exhaustion resolves to the absent arm on a failable node and to a throw on an always node, which the caller reports as a failed candidate. Flat emission writes the branch marker before the arm runs, so the rollback truncates the buffer rather than leaving a marker for an arm that lost.
    @inline(__always)
    static func handleBacktrack(
        _ choices: ContiguousArray<ReflectiveOperation.PickTuple>,
        continuation: (Any) throws -> AnyGenerator,
        inputValue: Any,
        context: inout Context,
        calleeFallback: ChoiceTree? = nil,
        continuationFallback: ChoiceTree? = nil
    ) throws -> (Any, ChoiceTree)? {
        // Auditioning can discard prefix choices and select a different arm. Keep its results scoped to their fallback context.
        context.record(.unknown)
        let branchCount = UInt64(choices.count)
        let fingerprint = choices[0].fingerprint
        // Exact resolution uses the jump seed only to materialize alternatives. Guided resolution still consumes it when alternatives are omitted because later PRNG fallbacks observe the stream position.
        let jumpSeed = context.mode == .exact && context.materializePicks == false ? 0 : context.prng.next()

        let fallbackBranch = selectedFallbackBranch(in: calleeFallback)
        let (branchBodyFallback, branchContinuationFallback) = decomposeNonGroupFallback(fallbackBranch?.choice)

        var audition = BacktrackAudition(choices)
        var pendingArm: ReflectiveOperation.PickTuple?
        switch context.mode {
            case .exact:
                guard let prefixBranch = context.cursor.tryConsumeBranch() else {
                    throw RejectionError()
                }
                context.record(.prefix)
                let exactIndex = Int(prefixBranch.id)
                guard exactIndex < choices.count else {
                    return nil
                }
                pendingArm = choices[exactIndex]

            case .guided:
                switch (context.cursor.tryConsumeBranch(), fallbackBranch) {
                    case let (prefixBranch?, _):
                        context.record(.prefix)
                        let guidedIndex = Int(prefixBranch.id)
                        guard guidedIndex < choices.count else {
                            return nil
                        }
                        pendingArm = choices[guidedIndex]
                    case let (nil, fallbackBranch?):
                        context.record(.fallbackTree)
                        let fallbackIndex = Int(fallbackBranch.id)
                        guard fallbackIndex < choices.count else {
                            return nil
                        }
                        pendingArm = choices[fallbackIndex]
                    case (nil, nil):
                        break
                }

            case .generate, .minimize:
                break
        }
        if let pendingArm {
            audition.exclude(id: pendingArm.id)
        }

        var selection: (arm: ReflectiveOperation.PickTuple, value: Any, tree: ChoiceTree, bodyStart: Int)?
        while selection == nil {
            let arm: ReflectiveOperation.PickTuple
            switch pendingArm {
                case let pending?:
                    arm = pending
                    pendingArm = nil
                case nil:
                    switch context.mode {
                        case .exact:
                            throw RejectionError()
                        case .minimize:
                            arm = try audition.nextInOrder()
                                ?? BacktrackAudition.resolveExhaustion(of: choices, reportingDiagnostic: false)
                        case .guided, .generate:
                            context.record(.prng)
                            arm = try audition.drawNext(using: &context.prng)?.arm
                                ?? BacktrackAudition.resolveExhaustion(of: choices, reportingDiagnostic: false)
                    }
            }
            let snapshot = context.auditionSnapshot()
            if context.skipTree {
                // Flat emission mirrors flatten's selected-branch group: group open, branch marker, branch body plus continuation (pair-grouped by runContinuation when the continuation is non-pure), group close.
                context.emitFlat(.group(true))
                context.emitFlat(.branch(.init(
                    id: arm.id,
                    branchCount: branchCount,
                    fingerprint: fingerprint
                )))
            }
            let bodyStart = context.flatCount
            // An oversized audition may return nil and yield to a smaller arm. Its temporary history is not a lower bound on the eventual selected history.
            let armResult = try context.withSuspendedSequenceCeiling { context in
                try generateRecursive(
                    arm.generator,
                    with: inputValue,
                    context: &context,
                    fallbackTree: branchBodyFallback
                )
            }
            guard let (value, tree) = armResult else {
                return nil
            }
            if StructuralEquality.isNilOptional(value), BacktrackAudition.isAbsentArm(arm, in: choices) == false {
                context.restore(snapshot)
                continue
            }
            selection = (arm, value, tree, bodyStart)
        }
        let (arm, value, tree, bodyStart) = selection!

        if context.skipTree {
            guard let continued = try runContinuation(
                result: value,
                calleeChoiceTree: .just,
                calleeStart: bodyStart,
                continuation: continuation,
                inputValue: inputValue,
                context: &context,
                continuationFallback: branchContinuationFallback ?? continuationFallback
            ) else {
                return nil
            }
            context.emitFlat(.group(false))
            return continued
        }

        guard let (continuationValue, continuationTree) = try runContinuation(
            result: value,
            calleeChoiceTree: tree,
            calleeStart: bodyStart,
            continuation: continuation,
            inputValue: inputValue,
            context: &context,
            continuationFallback: branchContinuationFallback ?? continuationFallback
        ) else {
            return nil
        }
        let selectedBranch = ChoiceTree.branch(
            fingerprint: fingerprint,
            weight: arm.weight,
            id: arm.id,
            branchCount: branchCount,
            choice: continuationTree,
            isSelected: true
        )
        guard context.materializePicks else {
            return (continuationValue, .group([selectedBranch]))
        }

        var branches = [ChoiceTree]()
        branches.reserveCapacity(choices.count)
        for choice in choices {
            if choice.id == arm.id {
                branches.append(selectedBranch)
            } else if let branch = try materializeUnselectedBranch(
                choice,
                fingerprint: fingerprint,
                branchCount: branchCount,
                jumpSeed: jumpSeed,
                continuation: continuation,
                inputValue: inputValue,
                size: context.size
            ) {
                branches.append(branch)
            }
        }
        return (continuationValue, .group(branches))
    }
}
