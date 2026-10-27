// MARK: - Collection Handlers

extension Materializer {
    // MARK: - sequence

    /// Materializes a variable-length sequence by resolving the length, then materializing each element in order.
    ///
    /// Length resolution is mode-dependent: exact mode validates the cursor's element count against explicit generator metadata, guided mode clamps cursor or fallback element counts to the generator's valid range, and generate mode runs the length generator fresh. After all elements are materialized the cursor's sequence-close marker is consumed so the caller's cursor position is consistent.
    @inline(__always)
    static func handleSequence(
        lengthGenerator: Generator<UInt64>,
        elementGenerator: AnyGenerator,
        elementBatch: ReflectiveOperation.SequenceElementBatch? = nil,
        continuation: (Any) throws -> AnyGenerator,
        inputValue: Any,
        context: inout Context,
        calleeFallback: ChoiceTree? = nil,
        continuationFallback: ChoiceTree? = nil
    ) throws -> (Any, ChoiceTree)? {
        let length: UInt64
        let lengthMetadata: ChoiceMetadata
        let elementFallbacks: [ChoiceTree]? = switch calleeFallback {
            case let .sequence(elements, _):
                elements
            default:
                nil
        }

        switch (context.cursor.tryConsumeSequenceOpen(), context.mode, elementFallbacks) {
            case let (sequenceInfo?, .exact, _):
                context.record(.prefix)
                let prefixCount = UInt64(sequenceInfo.elementCount)
                lengthMetadata = try extractLengthMetadata(lengthGenerator)
                if lengthMetadata.isRangeExplicit {
                    guard let validRange = lengthMetadata.validRange,
                          validRange.contains(prefixCount)
                    else {
                        throw RejectionError()
                    }
                }
                length = prefixCount
            case let (sequenceInfo?, _, _) where sequenceInfo.isLengthExplicit:
                context.record(.prefix)
                // Fixed-length generators always use their declared length; variable-length generators preserve the prefix count within their range.
                let prefixCount = UInt64(sequenceInfo.elementCount)
                lengthMetadata = try extractLengthMetadata(lengthGenerator)
                length = lengthMetadata.validRange.map { range in
                    Swift.min(Swift.max(prefixCount, range.lowerBound), range.upperBound)
                } ?? prefixCount
            case let (sequenceInfo?, _, _):
                context.record(.prefix)
                length = UInt64(sequenceInfo.elementCount)
                lengthMetadata = ChoiceMetadata(validRange: nil, isRangeExplicit: false)
            case (nil, .exact, _):
                throw RejectionError()
            case let (nil, _, elementFallbacks?):
                context.record(.fallbackTree)
                let resolvedLength = UInt64(elementFallbacks.count)
                lengthMetadata = try extractLengthMetadata(lengthGenerator)
                length = lengthMetadata.validRange.map { range in
                    Swift.min(Swift.max(resolvedLength, range.lowerBound), range.upperBound)
                } ?? resolvedLength
            case (nil, _, nil):
                // A fresh length walk has no replay boundary certifying the resulting structure.
                context.record(.unknown)
                let erasedLengthGenerator = lengthGenerator.erase()
                // The length walk's tree is discarded and flatten never contains length entries, so flat emission is suspended around it.
                let savedSuspension = context.flatEmissionSuspended
                let lengthResult: (Any, ChoiceTree)?
                do {
                    context.flatEmissionSuspended = true
                    defer { context.flatEmissionSuspended = savedSuspension }
                    lengthResult = try generateRecursive(
                        erasedLengthGenerator,
                        with: inputValue,
                        context: &context
                    )
                }
                guard let (freshLength, _) = lengthResult else {
                    return nil
                }
                // The length generator's output type is UInt64; type erasure occurs only at the interpreter boundary.
                length = freshLength as! UInt64
                lengthMetadata = try extractLengthMetadata(lengthGenerator)
        }

        let calleeStart = context.flatCount
        context.emitFlat(.sequence(
            true,
            validRange: lengthMetadata.validRange,
            isLengthExplicit: lengthMetadata.isRangeExplicit
        ))

        // `results` is reserved inside each element loop: the batch path returns without appending, and reserving allocates.
        var results: [Any] = []
        var elements: [ChoiceTree] = []
        // Unwrap a forward-inert contramap layer once, before the loop: materialization ignores the backward transform, so character-style elements (contramap over chooseBits) can take the fused loop below as long as the wrapper's continuation is applied to each element.
        var fusedElementGenerator = elementGenerator
        var contramapContinuation: ((Any) throws -> AnyGenerator)?
        var wrapperForward: ((Any) throws -> Any)?
        switch elementGenerator {
            case let .impure(.contramap(_, innerGenerator), continuation: outerContinuation):
                fusedElementGenerator = innerGenerator
                contramapContinuation = outerContinuation
            case let .impure(.transform(.isomorph(forward, _, _, _), innerGenerator), continuation: outerContinuation),
                 let .impure(.transform(.map(forward, _, _, _), innerGenerator), continuation: outerContinuation):
                // A transparent transform wrapper peels the same way as a contramap, with its forward applied to each element before the wrapper's own continuation.
                fusedElementGenerator = innerGenerator
                contramapContinuation = outerContinuation
                wrapperForward = forward
            default:
                break
        }

        // Each batched scalar contributes one entry, plus the sequence's two markers. Reject before reserving arrays or evaluating elements; enclosing structure can only add entries. Other element shapes retain the final complete-history check.
        if context.flatEmissionSuspended == false,
           elementBatch != nil,
           case .impure(.chooseBits, _) = fusedElementGenerator,
           context.sequenceCeiling.admits(arrayLength: length) == false
        {
            throw RejectionError()
        }
        if context.skipTree == false {
            elements.reserveCapacity(Int(length))
        }

        if let elementBatch, case let .impure(
            .chooseBits(
                elementMin,
                elementMax,
                elementTag,
                elementIsRangeExplicit,
                elementScaling,
                elementTypeTagPayload
            ),
            _
        ) = fusedElementGenerator {
            let bits = try tryReplayScalarBits(
                length: length,
                min: elementMin,
                max: elementMax,
                tag: elementTag,
                isRangeExplicit: elementIsRangeExplicit,
                context: &context
            ) ?? resolveScalarBatchBits(
                length: length,
                min: elementMin,
                max: elementMax,
                tag: elementTag,
                isRangeExplicit: elementIsRangeExplicit,
                scaling: elementScaling,
                typeTagPayload: elementTypeTagPayload,
                elementFallbacks: elementFallbacks,
                elements: &elements,
                context: &context
            )
            context.emitFlat(.sequence(false))
            context.cursor.skipSequenceClose()

            let choiceTree: ChoiceTree = context.skipTree
                ? .just
                : .sequence(elements: elements, metadata: lengthMetadata)

            return try runContinuation(
                result: elementBatch.convert(bits),
                calleeChoiceTree: choiceTree,
                calleeStart: calleeStart,
                continuation: continuation,
                inputValue: inputValue,
                context: &context,
                continuationFallback: continuationFallback
            )
        }
        var elementIndex = 0
        var remaining = length
        if case let .impure(
            .chooseBits(
                elementMin,
                elementMax,
                elementTag,
                elementIsRangeExplicit,
                elementScaling,
                elementTypeTagPayload
            ),
            elementContinuation
        ) = fusedElementGenerator {
            // Fused loop: skips the per-element dispatch through generateRecursive (and the contramap frame when present). Fallback decomposition matches what the dispatch switch performs for a bare chooseBits — handleContramap passes the element fallback through untouched, so decomposing here is equivalent for both shapes.
            results.reserveCapacity(Int(length))
            while remaining > 0 {
                let elementFallback: ChoiceTree? = elementFallbacks.flatMap { fallbacks in
                    elementIndex < fallbacks.count ? fallbacks[elementIndex] : nil
                }
                let (elementCalleeFallback, elementContinuationFallback) = decomposeNonGroupFallback(elementFallback)
                let elementStart = context.flatCount
                let elementOutcome = try handleChooseBits(
                    min: elementMin,
                    max: elementMax,
                    tag: elementTag,
                    isRangeExplicit: elementIsRangeExplicit,
                    scaling: elementScaling,
                    typeTagPayload: elementTypeTagPayload,
                    continuation: elementContinuation,
                    inputValue: inputValue,
                    context: &context,
                    calleeFallback: elementCalleeFallback,
                    continuationFallback: elementContinuationFallback
                )
                guard let (innerResult, innerTree) = elementOutcome else {
                    return nil
                }
                let result: Any
                let element: ChoiceTree
                let wrappedResult = try wrapperForward?(innerResult) ?? innerResult
                switch contramapContinuation {
                    case let continuation?:
                        guard let continued = try runContinuation(
                            result: wrappedResult,
                            calleeChoiceTree: innerTree,
                            calleeStart: elementStart,
                            continuation: continuation,
                            inputValue: inputValue,
                            context: &context,
                            continuationFallback: nil
                        ) else {
                            return nil
                        }
                        (result, element) = continued
                    case nil:
                        (result, element) = (innerResult, innerTree)
                }
                results.append(result)
                if context.skipTree == false {
                    elements.append(element)
                }
                elementIndex += 1
                remaining -= 1
            }
        } else {
            results.reserveCapacity(Int(length))
            while remaining > 0 {
                let elementFallback: ChoiceTree? = elementFallbacks.flatMap { fallbacks in
                    elementIndex < fallbacks.count ? fallbacks[elementIndex] : nil
                }
                guard let (result, element) = try generateRecursive(
                    elementGenerator,
                    with: inputValue,
                    context: &context,
                    fallbackTree: elementFallback
                ) else {
                    return nil
                }
                results.append(result)
                if context.skipTree == false {
                    elements.append(element)
                }
                elementIndex += 1
                remaining -= 1
            }
        }

        context.emitFlat(.sequence(false))
        context.cursor.skipSequenceClose()

        let choiceTree: ChoiceTree = context.skipTree
            ? .just
            : .sequence(elements: elements, metadata: lengthMetadata)

        return try runContinuation(
            result: results,
            calleeChoiceTree: choiceTree,
            calleeStart: calleeStart,
            continuation: continuation,
            inputValue: inputValue,
            context: &context,
            continuationFallback: continuationFallback
        )
    }

    // MARK: - zip

    /// Materializes each component of a zip in declaration order, collecting results into an array for the continuation.
    ///
    /// Each child is scoped so cursor reads cannot bleed into sibling components. The primary scope source is the prefix's own parsed subtree spans (`prefixChildEnds`); when the prefix does not parse at this site, per-child entry counts from the fallback tree stand in. See ``Cursor/zipChildSubtreeEnds(count:)`` for why the prefix is authoritative.
    @inline(__always)
    static func handleZip(
        _ generators: ContiguousArray<AnyGenerator>,
        continuation: (Any) throws -> AnyGenerator,
        inputValue: Any,
        context: inout Context,
        calleeFallback: ChoiceTree? = nil,
        continuationFallback: ChoiceTree? = nil,
        prefixChildEnds: [Int]? = nil
    ) throws -> (Any, ChoiceTree)? {
        let fallbackChildren: [ChoiceTree]? = calleeFallback.flatMap { fallback -> [ChoiceTree]? in
            guard case let .group(children, _, _) = fallback,
                  children.count == generators.count
            else {
                return nil
            }
            return children
        }

        var results = [Any]()
        results.reserveCapacity(generators.count)
        var choiceTrees: [ChoiceTree] = []
        if context.skipTree == false {
            choiceTrees.reserveCapacity(generators.count)
        }

        let canScope = (prefixChildEnds != nil || fallbackChildren != nil) && context.cursor.isSpent == false
        let boundarySources: MaterializationSources = switch (prefixChildEnds, fallbackChildren, canScope) {
            case (.some, _, _):
                .prefix
            case (nil, .some, true):
                .fallbackTree
            default:
                .unknown
        }
        context.record(boundarySources)

        let calleeStart = context.flatCount
        context.emitFlat(.zip(true))

        // Scope limits come from the prefix's parsed spans (`prefixChildEnds`, absolute end positions; see Cursor.zipChildSubtreeEnds(count:)). When the prefix does not parse at this site, the fallback tree's per-child entry counts stand in: cumulative flattenedEntryCount from basePosition + 1, which avoids the cursor-position drift skipGroups() used to cause.
        // Past the zip open. The cursor can stand on slack ahead of the open, which the open index looks past; when the open is behind the cursor, its position bounds the first child from below.
        var childScopeStart = (context.cursor.zipOpenIndex ?? context.cursor.position) + 1

        // Advance the cursor past transparent markers so it is ready for the first child's consume calls (tryConsumeBranch / tryConsumeValue).
        if canScope {
            context.cursor.skipGroups()
        }

        // while-loop: avoiding zip/IteratorProtocol overhead in debug builds.
        var zipIndex = 0
        while zipIndex < generators.count {
            let generator = generators[zipIndex]
            let fallback: ChoiceTree? = fallbackChildren?[zipIndex]
            // Scope limits only constrain cursor reads, so a spent cursor (empty prefix, or a candidate consumed mid-zip) needs none of this bookkeeping, in particular not flattenedEntryCount, an uncached tree walk. Spent is monotonic, so children after this one skip it too.
            let isCursorLive = canScope && context.cursor.isSpent == false
            // flattenedEntryCount is skipped when the prefix supplies the spans: the arithmetic fallback is never consulted at this site once prefixChildEnds is non-nil.
            let entryCount = (isCursorLive && prefixChildEnds == nil) ? fallback?.flattenedEntryCount : nil
            let scopeLimit: Int? = isCursorLive
                ? prefixChildEnds?[zipIndex] ?? entryCount.map { childScopeStart + $0 }
                : nil
            if let scopeLimit {
                context.cursor.pushScope(limit: scopeLimit)
            }
            guard let (result, tree) = try generateRecursive(
                generator,
                with: inputValue,
                context: &context,
                fallbackTree: fallback
            ) else {
                if scopeLimit != nil {
                    context.cursor.popScope()
                }
                return nil
            }
            if scopeLimit != nil {
                context.cursor.popScope()
            }
            if canScope {
                context.cursor.skipGroupCloses()
            }
            if let entryCount {
                childScopeStart += entryCount
            }
            results.append(result)
            if context.skipTree == false {
                choiceTrees.append(tree)
            }
            zipIndex += 1
        }
        context.emitFlat(.zip(false))
        let calleeTree: ChoiceTree = context.skipTree ? .just : .group(choiceTrees, isZip: true)
        return try runContinuation(
            result: results,
            calleeChoiceTree: calleeTree,
            calleeStart: calleeStart,
            continuation: continuation,
            inputValue: inputValue,
            context: &context,
            continuationFallback: continuationFallback
        )
    }

    /// Extracts ``ChoiceMetadata`` (valid range and explicitness) from a sequence's length generator without running a full materialization round-trip.
    ///
    /// Handles three common shapes: a bare ``ReflectiveOperation/chooseBits``, a ``ReflectiveOperation/getSize``-wrapped chooseBits, and the contramap-wrapped non-reified size form. Returns empty metadata when the generator has an unrecognized shape, which causes the caller to skip range clamping.
    private static func extractLengthMetadata(
        _ lengthGenerator: Generator<UInt64>
    ) throws -> ChoiceMetadata {
        if case let .impure(.chooseBits(min, max, _, isRangeExplicit, _, _), _) = lengthGenerator {
            return ChoiceMetadata(validRange: min ... max, isRangeExplicit: isRangeExplicit)
        }
        if let sizeContinuation = lengthGenerator.getSizeContinuation,
           case let .impure(
               .chooseBits(min, max, _, isRangeExplicit, _, _),
               _
           ) = try sizeContinuation(UInt64(100) as Any)
        {
            return ChoiceMetadata(validRange: min ... max, isRangeExplicit: isRangeExplicit)
        }
        return ChoiceMetadata(validRange: nil, isRangeExplicit: false)
    }
}
