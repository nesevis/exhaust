//
//  ChoiceTreeAnalysis.swift
//  Exhaust
//

/// Extracts parameter domains from a generator's choice tree for t-way covering array construction.
///
/// ## What It Does
///
/// Runs a generator through the ``ValueAndChoiceTreeInterpreter`` (VACTI) with `materializePicks = true` to produce a complete ``ChoiceTree`` — a data structure that records every choice the generator made, including all branches points. Walks the tree to identify independent parameters: numeric choices, branch selections (picks), and sequence lengths/elements. Classifies the generator as enumerable (all parameters have at most 256 values) or large-domain (some parameters have large ranges, requiring synthetic problematic value representatives). Returns a ``EnumerableDomainProfile`` or ``LargeDomainProfile`` that downstream code uses to build covering arrays.
///
/// ## Why This Matters
///
/// Standard random testing misses systematic parameter interactions. A generator with three booleans and a 4-way enum has 32 combinations — random sampling at 100 iterations will likely miss some. t-way combinatorial testing guarantees that every t-tuple of parameter values appears in at least one test case. Strength t=2 (pairwise) catches all two-parameter interactions; t=3 catches all three-parameter interactions. The covering array approach produces far fewer test cases than exhaustive enumeration. For example, pairwise coverage of five boolean parameters needs only four test cases instead of 32. ChoiceTreeAnalysis is what makes this possible: it decomposes an opaque generator into a parameter model suitable for combinatorial construction.
///
/// ## How Exhaust Enables Deep Analysis
///
/// Generators built by composing closures are resistant to analysis because each closure boundary is opaque — a static walker cannot inspect what a `bind` continuation will do until it runs. Exhaust's Freer Monad architecture sidesteps this: instead of embedding decisions in closures, every generator choice is reified as an inspectable ``ReflectiveOperation`` node. When VACTI interprets the generator with `materializePicks = true`, it executes the full generator pipeline once and produces a concrete ``ChoiceTree`` that records every decision — including those produced by bind continuations, nested picks, and recursive layers. The analysis then walks this execution trace rather than the generator structure, extracting a complete parameter model from a single run. Trade-off: the analysis reflects one execution path. Different PRNG seeds can produce different sequence lengths. The analysis tries three seeds and keeps the result with the most parameters.
///
/// ## Parameter Classification
///
/// Six ``ScreeningParameterKind`` cases:
/// - `.enumerableChooseBits`: domain size is 256 or smaller — enumerates all values.
/// - `.chooseBits`: domain size exceeds 256 — synthesizes problematic values {min, min+1, midpoint, max-1, max, zero if in range}. Floats and dates have type-specific problematic sets.
/// - `.compositeSequence`: a single parameter encoding all valid `(length, [element problematic values])` configurations for a sequence. The domain enumerates empty (if allowed), single-element, and optionally two-element problematic combinations. Element analysis is capped at two slots.
/// - `.sequenceLength`, `.sequenceElement`: legacy cases used by the ``SequenceCoveringArray`` pipeline. Not produced by ``walkSequence``.
/// - `.pick`: multi-way branch — values are branch indices. Analyzable when the branch count is 256 or fewer and all branches are structurally valid. Nested parameters within branches are allowed but not extracted — the covering array varies the branch index while the materializer's PRNG fills in values within the selected branch.
///
/// ## Analyzability
///
/// Every generator that contains at least one random choice point (a `chooseBits`, `pick`, or `sequence`) is analyzable. The ``analyze(_:)`` method returns `nil` only when zero parameters are extracted — that is, the generator is purely deterministic (for example `Gen.just(value)`).
///
/// - SeeAlso: ``BalancedCoveringArrayGenerator``, ``ScreeningRunner``, ``ProblematicValues``
package enum ChoiceTreeAnalysis {
    /// The outcome of analyzing a generator's choice tree structure.
    public enum AnalysisResult {
        /// All parameters have at most 256 values. Eligible for exhaustive enumeration or t-way covering.
        case enumerable(EnumerableDomainProfile)
        /// At least one parameter has a large domain. Uses synthetic problematic values for covering array construction.
        case large(LargeDomainProfile)
    }

    private static let enumerableDomainThreshold: UInt64 = 256

    private static let seeds: [UInt64] = [
        0x600D_F00D_600D_E665,
        0xF165_BEEF_C0D5_A6E0,
        0xF0CC_AC1A_C0FF_EE50,
    ]

    /// Analyzes a generator by running it through VACTI and walking the resulting ChoiceTree.
    ///
    /// Returns `.enumerable` if all parameters have small domains (≤256 values), `.large` if some parameters need problematic value synthesis, or `nil` if zero parameters are extracted (the generator is purely deterministic).
    ///
    /// Tries multiple seeds to maximize element coverage for sequences.
    ///
    /// - Parameters:
    ///   - expandSequencePairs: When `true`, two-element configurations give both positions the full element catalog (N² pair entries), degrading per slot to disjoint halves ((N/2)² entries) when the full model exceeds `compositeThreshold`. When `false`, every two-element configuration uses disjoint halves. ``ScreeningRunner`` passes `false` on retry when the flattened pair product exceeds its model budget.
    ///   - compositeThreshold: Composite sequence parameters whose domain exceeds this value after problematic-value conversion and pair halving go opaque. Defaults to ``enumerableDomainThreshold``. ``ScreeningRunner`` passes its model budget so composite domains stay within what rotated covering runs can sweep.
    public static func analyze(
        _ gen: Generator<some Any>,
        expandSequencePairs: Bool = true,
        compositeThreshold: UInt64? = nil
    ) -> AnalysisResult? {
        let effectiveCompositeThreshold = compositeThreshold ?? enumerableDomainThreshold
        var bestParameters: [ScreeningParameter]?
        var bestTree: ChoiceTree?

        for seed in seeds {
            // `sizeOverride: 100` ensures size-scaled sequences produce non-empty element subtrees during VACTI so that ``walkSequence`` can extract element parameters. The declared range itself is already stored directly on each `chooseBits` (with scaling attached as metadata), so the analyzer doesn't need a specific size for range visibility — just a size at which sequences produce enough elements to walk.
            var interpreter = ValueAndChoiceTreeInterpreter(
                gen,
                materializePicks: true,
                seed: seed,
                maxRuns: 1,
                sizeOverride: 100
            )

            interpreter.prepareForScreeningAnalysis()
            guard let (_, tree) = try? interpreter.next() else {
                return nil
            }

            var parameters: [ScreeningParameter] = []
            guard walkTree(tree, expandSequencePairs: expandSequencePairs, compositeThreshold: effectiveCompositeThreshold, parameters: &parameters) else {
                return nil
            }

            if bestParameters == nil || parameters.count > (bestParameters?.count ?? 0) {
                bestParameters = parameters
                bestTree = tree
            }

            let hasIncompleteSequence = parameters.contains { param in
                if case let .compositeSequence(_, elementSlotParams, _, _) = param.kind {
                    return elementSlotParams.count < 2
                }
                return false
            }
            if hasIncompleteSequence == false { break }
        }

        guard let parameters = bestParameters, parameters.isEmpty == false else {
            return nil
        }
        let allEnumerable = parameters.allSatisfy { param in
            switch param.kind {
                case .enumerableChooseBits, .pick:
                    true
                case .chooseBits, .sequenceLength, .sequenceElement, .compositeSequence:
                    false
            }
        }

        if allEnumerable {
            let enumerableParams = parameters.enumerated().map { i, param -> EnumerableParameter in
                switch param.kind {
                    case let .enumerableChooseBits(range, tag):
                        return EnumerableParameter(
                            index: i,
                            domainSize: param.domainSize,
                            kind: .chooseBits(range: range, tag: tag)
                        )
                    case let .pick(choices):
                        return EnumerableParameter(
                            index: i,
                            domainSize: param.domainSize,
                            kind: .pick(choices: choices)
                        )
                    default:
                        fatalError("unreachable: allEnumerable check passed")
                }
            }
            var totalSpace: UInt64 = 1
            for param in enumerableParams {
                let (product, overflow) =
                    totalSpace.multipliedReportingOverflow(by: param.domainSize)
                if overflow {
                    totalSpace = .max
                    break
                }
                totalSpace = product
            }
            let profile = EnumerableDomainProfile(
                parameters: enumerableParams,
                totalSpace: totalSpace,
                originalTree: bestTree
            )
            return .enumerable(profile)
        } else {
            let profile = LargeDomainProfile(
                parameters: parameters,
                originalTree: bestTree
            )
            return .large(profile)
        }
    }

    // MARK: - Tree Walk

    //
    // The shared shape classifier chooses traversable edges and parameter sites; domain builders decide whether those sites fit the screening model.

    /// Recursively walks a ``ChoiceTree``, extracting independent parameters into `parameters`.
    ///
    /// Uses the same shape classification as row reconstruction, including the narrower traversal inside sequence slots. Domain construction remains specific to each parameter kind.
    private static func walkTree(
        _ tree: ChoiceTree,
        expandSequencePairs: Bool,
        compositeThreshold: UInt64,
        scope: ScreeningScope = .root,
        parameters: inout [ScreeningParameter]
    ) -> Bool {
        switch tree.screeningShape(in: scope) {
            case .preserved:
                return true
            case .invalid:
                return false
            case let .choice(value, metadata):
                return walkChoice(value: value, metadata: metadata, scope: scope, parameters: &parameters)
            case let .pick(children):
                return walkPick(children, parameters: &parameters)
            case let .singleton(branch, _):
                return walkTree(
                    branch.choice,
                    expandSequencePairs: expandSequencePairs,
                    compositeThreshold: compositeThreshold,
                    scope: scope,
                    parameters: &parameters
                )
            case let .group(children, _), let .resize(_, children):
                for child in children {
                    guard walkTree(
                        child,
                        expandSequencePairs: expandSequencePairs,
                        compositeThreshold: compositeThreshold,
                        scope: scope,
                        parameters: &parameters
                    ) else { return false }
                }
                return true
            case let .bind(_, inner, bound, visitsBound):
                guard walkTree(
                    inner,
                    expandSequencePairs: expandSequencePairs,
                    compositeThreshold: compositeThreshold,
                    scope: scope,
                    parameters: &parameters
                ) else { return false }
                guard visitsBound else { return walkTreeValidateOnly(bound) }
                return walkTree(
                    bound,
                    expandSequencePairs: expandSequencePairs,
                    compositeThreshold: compositeThreshold,
                    scope: scope,
                    parameters: &parameters
                )
            case let .sequence(elements, metadata):
                return walkSequence(
                    length: UInt64(elements.count),
                    elements: elements,
                    metadata: metadata,
                    expandSequencePairs: expandSequencePairs,
                    compositeThreshold: compositeThreshold,
                    parameters: &parameters
                )
        }
    }

    // MARK: - Validation-Only Walk

    //
    // Walks a subtree without extracting parameters. Used for bound subtrees in bind nodes where the structure must be valid but parameters are opaque. Always returns true — no node type is rejected in validation-only mode.

    private static func walkTreeValidateOnly(_ tree: ChoiceTree) -> Bool {
        switch tree {
            case .choice, .just, .getSize, .resize:
                true
            case .group(_, isOpaque: true, _):
                true
            case let .group(children, _, _):
                children.allSatisfy { walkTreeValidateOnly($0) }
            case let .bind(_, inner, bound):
                walkTreeValidateOnly(inner) && walkTreeValidateOnly(bound)
            case let .sequence(elements, _):
                elements.allSatisfy { walkTreeValidateOnly($0) }
            case let .branch(b):
                walkTreeValidateOnly(b.choice)
        }
    }

    // MARK: - Choice

    //
    // Processes numeric sites approved by the shape classifier. Computes domain size via subtractingReportingOverflow to handle full-range UInt64. Small domains enumerate all values; large domains use problematic-value representatives.

    private static func walkChoice(
        value: ChoiceValue,
        metadata: ChoiceMetadata,
        scope: ScreeningScope,
        parameters: inout [ScreeningParameter]
    ) -> Bool {
        // Size-scaled ranges are visible because analysis runs at size 100; participation is decided by screeningShape.
        guard let range = metadata.validRange else {
            return false
        }

        let typeTag = value.tag
        let (domainSize, overflow) = range.upperBound.subtractingReportingOverflow(range.lowerBound)
        let isSmall = overflow == false && domainSize < enumerableDomainThreshold

        if isSmall {
            let count = domainSize + 1
            let param = ScreeningParameter(
                index: parameters.count,
                values: Array(range.lowerBound ... range.upperBound),
                domainSize: count,
                kind: .enumerableChooseBits(range: range, tag: typeTag)
            )
            parameters.append(param)
        } else {
            let problematicValues = ProblematicValues.computeProblematicValues(
                min: range.lowerBound, max: range.upperBound, tag: typeTag, payload: metadata.typeTagPayload
            )
            let kind: ScreeningParameterKind = switch scope {
                case .root: .chooseBits(range: range, tag: typeTag)
                case let .element(index): .sequenceElement(elementIndex: index, range: range, tag: typeTag)
            }
            let param = ScreeningParameter(
                index: parameters.count,
                values: problematicValues,
                domainSize: UInt64(problematicValues.count),
                kind: kind
            )
            parameters.append(param)
        }
        return true
    }

    // MARK: - Pick Domains

    //
    // Pick analysis requires ≤ 256 branches and structurally valid subtrees. Nested parameters within branches are allowed but not extracted — the covering array varies the branch index while the materializer's PRNG fills in values within the selected branch.
    //
    // Synthetic PickTuples are created with .pure(()) generators because the original branch generators are not available from the ChoiceTree.
    // The fingerprint, weight, id, and branchCount metadata is preserved for replay compatibility — CoveringArrayReplay uses these to reconstruct the branch selection.

    private static func walkPick(
        _ children: [ChoiceTree],
        parameters: inout [ScreeningParameter]
    ) -> Bool {
        let domainSize = UInt64(children.count)
        guard domainSize <= enumerableDomainThreshold else { return false }

        for child in children {
            guard case let .branch(b) = child else { return false }
            guard walkTreeValidateOnly(b.choice) else { return false }
        }

        // Create synthetic PickTuples from branch metadata for replay compatibility
        var pickTuples = ContiguousArray<ReflectiveOperation.PickTuple>()
        for child in children {
            guard case let .branch(b) = child else { return false }
            pickTuples.append(ReflectiveOperation.PickTuple(
                fingerprint: b.fingerprint,
                id: b.id,
                weight: b.weight,
                generator: .pure(())
            ))
        }

        let param = ScreeningParameter(
            index: parameters.count,
            values: Array(0 ..< domainSize),
            domainSize: domainSize,
            kind: .pick(choices: pickTuples)
        )
        parameters.append(param)
        return true
    }

    // MARK: - Sequence

    //
    // Builds a single composite parameter encoding all valid (length, [element problematic values]) configurations. The domain enumerates empty (if allowed), single-element, and optionally two-element problematic combinations. Element analysis is capped at two slots.

    private static func walkSequence(
        length _: UInt64,
        elements: [ChoiceTree],
        metadata: ChoiceMetadata,
        expandSequencePairs: Bool,
        compositeThreshold: UInt64,
        parameters: inout [ScreeningParameter]
    ) -> Bool {
        guard let lengthRange = metadata.validRange else {
            return false
        }

        let clampedUpperBound = lengthRange.upperBound > UInt64(Int.max) ? Int.max : Int(lengthRange.upperBound)
        let maxElementSlots = min(2, clampedUpperBound, elements.count)
        var elementSlotParams: [[ScreeningParameter]] = []
        for elementIndex in 0 ..< maxElementSlots {
            var slotParams: [ScreeningParameter] = []
            guard walkTree(
                elements[elementIndex],
                expandSequencePairs: expandSequencePairs,
                compositeThreshold: compositeThreshold,
                scope: .element(elementIndex),
                parameters: &slotParams
            ) else {
                return false
            }
            elementSlotParams.append(slotParams)
        }

        let baseMaxLength: UInt64 = elementSlotParams.count >= 2 ? 2 : min(1, UInt64(maxElementSlots))
        let maxAnalyzedLength = max(baseMaxLength, lengthRange.lowerBound)
        let lengthValues = Set([0, 1, 2, lengthRange.lowerBound])
            .filter { $0 <= maxAnalyzedLength && lengthRange.contains($0) }
            .sorted()

        func buildSlots(
            from elementSlotParams: [[ScreeningParameter]],
            halvedPairs: Bool
        ) -> (slots: [SequenceLengthSlot], compositeSize: UInt64) {
            var slots: [SequenceLengthSlot] = []
            var offset: UInt64 = 0

            for length in lengthValues {
                let activeCount = min(Int(length), elementSlotParams.count)
                let params = (halvedPairs && activeCount >= 2)
                    ? halveElementSlotParams(elementSlotParams)
                    : elementSlotParams
                let contribution: UInt64
                if activeCount == 0 {
                    contribution = 1
                } else {
                    contribution = params.prefix(activeCount)
                        .reduce(UInt64(1)) { accumulator, slotParams in
                            slotParams.reduce(accumulator) { inner, param in
                                let (product, overflow) = inner.multipliedReportingOverflow(by: param.domainSize)
                                return overflow ? .max : product
                            }
                        }
                }

                slots.append(SequenceLengthSlot(
                    length: length,
                    flatOffset: offset,
                    contribution: contribution,
                    activeElementCount: activeCount
                ))

                let (sum, overflow) = offset.addingReportingOverflow(contribution)
                offset = overflow ? .max : sum
            }
            return (slots, offset)
        }

        var halvedPairs = false
        var (slots, compositeSize) = buildSlots(from: elementSlotParams, halvedPairs: false)

        // When the composite domain exceeds the enumerable threshold, enumerable element params whose products dominate the space should use problematic representatives instead of full enumeration.
        if compositeSize > Self.enumerableDomainThreshold {
            var converted = false
            for slotIndex in elementSlotParams.indices {
                for paramIndex in elementSlotParams[slotIndex].indices {
                    let param = elementSlotParams[slotIndex][paramIndex]
                    if case let .enumerableChooseBits(range, tag) = param.kind {
                        let problematicValues = ProblematicValues.computeProblematicValues(
                            min: range.lowerBound, max: range.upperBound, tag: tag
                        )
                        elementSlotParams[slotIndex][paramIndex] = ScreeningParameter(
                            index: param.index,
                            values: problematicValues,
                            domainSize: UInt64(problematicValues.count),
                            kind: .sequenceElement(elementIndex: slotIndex, range: range, tag: tag)
                        )
                        converted = true
                    }
                }
            }
            if converted {
                (slots, compositeSize) = buildSlots(from: elementSlotParams, halvedPairs: false)
            }
        }

        // Halving keeps length 2 but gives each position a disjoint half of the problematic values. Length ≤1 keeps the full set so every problematic value appears at least once. This reduces the length-2 product from d² to (d/2)² = d²/4 while still exercising pair interactions. Two triggers: the caller opted out of full pair expansion, or this slot's full model exceeds the threshold and only the halved model can keep the slot from going opaque. Halving must precede the threshold check for the second trigger to exist: checking the unhalved size first would drop the slots the halved model is for (an array of dates fits the threshold only after halving).
        if elementSlotParams.count >= 2, expandSequencePairs == false || compositeSize > compositeThreshold {
            halvedPairs = true
            (slots, compositeSize) = buildSlots(from: elementSlotParams, halvedPairs: true)
        }

        if compositeSize > compositeThreshold {
            return true
        }

        let param = ScreeningParameter(
            index: parameters.count,
            values: Array(0 ..< compositeSize),
            domainSize: compositeSize,
            kind: .compositeSequence(
                lengthRange: lengthRange,
                elementSlotParams: elementSlotParams,
                halvedPairs: halvedPairs,
                lengthSlots: slots
            )
        )
        parameters.append(param)
        return true
    }

    // MARK: - Element Pair Halving

    /// Splits each element slot's problematic values between positions: slot 0 gets the first half, slot 1 gets the second half.
    static func halveElementSlotParams(_ params: [[ScreeningParameter]]) -> [[ScreeningParameter]] {
        guard params.count >= 2 else { return params }
        var result = params
        let pairCount = min(result[0].count, result[1].count)
        for paramIndex in 0 ..< pairCount {
            let (firstHalf, secondHalf) = result[0][paramIndex].values.halved()
            result[0][paramIndex] = result[0][paramIndex].withValues(firstHalf)
            result[1][paramIndex] = result[1][paramIndex].withValues(secondHalf)
        }
        return result
    }
}
