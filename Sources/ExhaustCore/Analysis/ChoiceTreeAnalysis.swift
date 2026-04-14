//
//  ChoiceTreeAnalysis.swift
//  Exhaust
//

/// Extracts parameter domains from a generator's choice tree for t-way covering array construction.
///
/// ## What It Does
///
/// Runs a generator through the ``ValueAndChoiceTreeInterpreter`` (VACTI) with `materializePicks = true` to produce a complete ``ChoiceTree`` — a data structure that records every choice the generator made, including all branches points. Walks the tree to identify independent parameters: numeric choices, branch selections (picks), and sequence lengths/elements. Classifies the generator as finite-domain (all parameters have at most 256 values) or boundary-domain (some parameters have large ranges, requiring synthetic boundary value representatives). Returns a ``FiniteDomainProfile`` or ``BoundaryDomainProfile`` that downstream code uses to build covering arrays.
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
/// Five ``BoundaryParameterKind`` cases:
/// - `.finiteChooseBits`: domain size is 256 or smaller — enumerates all values.
/// - `.chooseBits`: domain size exceeds 256 — synthesizes boundary values {min, min+1, midpoint, max-1, max, zero if in range}. Floats and dates have type-specific boundary sets.
/// - `.sequenceLength`: sequence node — tests lengths {0, 1, 2} (intersection with the declared length range). Capped at 2 elements to keep parameter count tractable.
/// - `.sequenceElement`: element within a sequence — boundary values for the element's range, tagged with its position index.
/// - `.pick`: multi-way branch — values are branch indices. Only analyzable if the branch count is 256 or fewer and all branches are parameter-free (no nested choices).
///
/// ## Analyzability Constraints
///
/// The ``analyze(_:)`` method returns `nil` when:
/// - The generator uses `getSize` or `resize` (size-scaled generation is not analyzable).
/// - A branch within a pick contains nested choices (parameters inside branches).
/// - No explicit range metadata exists on a choice node (non-explicit ranges come from size scaling).
/// - Zero parameters are extracted.
///
/// - SeeAlso: ``PullBasedCoveringArrayGenerator``, ``CoverageRunner``, ``BoundaryDomainAnalysis``
public enum ChoiceTreeAnalysis {
    public enum AnalysisResult {
        /// All parameters have at most 256 values. Eligible for exhaustive enumeration or t-way covering.
        case finite(FiniteDomainProfile)
        /// At least one parameter has a large domain. Uses synthetic boundary values for covering array construction.
        case boundary(BoundaryDomainProfile)
    }

    private static let finiteDomainThreshold: UInt64 = 256

    private static let seeds: [UInt64] = [
        0x600D_F00D_600D_E665,
        0xF165_BEEF_C0D5_A6E0,
        0xF0CC_AC1A_C0FF_EE50,
    ]

    /// Analyzes a generator by running it through VACTI and walking the resulting ChoiceTree.
    ///
    /// Returns `.finite` if all parameters have small domains (≤256 values), `.boundary` if some parameters need boundary value synthesis, or `nil` if the generator is not analyzable (for example, uses getSize/resize).
    ///
    /// Tries multiple seeds to maximize element coverage for sequences.
    public static func analyze(_ gen: ReflectiveGenerator<some Any>) -> AnalysisResult? {
        var bestParameters: [BoundaryParameter]?
        var bestTree: ChoiceTree?

        for seed in seeds {
            var interpreter = ValueAndChoiceTreeInterpreter(
                gen,
                materializePicks: true,
                seed: seed,
                maxRuns: 1
            )

            guard let (_, tree) = try? interpreter.next() else {
                return nil
            }

            var parameters: [BoundaryParameter] = []
            guard walkTree(tree, parameters: &parameters) else {
                return nil
            }

            if bestParameters == nil || parameters.count > (bestParameters?.count ?? 0) {
                bestParameters = parameters
                bestTree = tree
            }

            // FIXME: Harsh syntax, rewrite
            // If we have no sequences, or all sequences produced enough elements, stop early
            let hasIncompleteSequence = parameters.contains { param in
                if case .sequenceLength = param.kind { return true }
                return false
            } && !parameters.contains { param in
                if case .sequenceElement(elementIndex: 1, _, _) = param.kind { return true }
                return false
            }
            if !hasIncompleteSequence { break }
        }

        guard let parameters = bestParameters, !parameters.isEmpty else {
            return nil
        }
        let allFinite = parameters.allSatisfy { param in
            switch param.kind {
            case .finiteChooseBits, .pick:
                true
            case .chooseBits, .sequenceLength, .sequenceElement:
                false
            }
        }

        if allFinite {
            let finiteParams = parameters.enumerated().map { i, param -> FiniteParameter in
                switch param.kind {
                case let .finiteChooseBits(range, tag):
                    return FiniteParameter(
                        index: i,
                        domainSize: param.domainSize,
                        kind: .chooseBits(range: range, tag: tag)
                    )
                case let .pick(choices):
                    return FiniteParameter(
                        index: i,
                        domainSize: param.domainSize,
                        kind: .pick(choices: choices)
                    )
                default:
                    fatalError("unreachable: allFinite check passed")
                }
            }
            var totalSpace: UInt64 = 1
            for param in finiteParams {
                let (product, overflow) =
                    totalSpace.multipliedReportingOverflow(by: param.domainSize)
                if overflow {
                    totalSpace = .max
                    break
                }
                totalSpace = product
            }
            let profile = FiniteDomainProfile(
                parameters: finiteParams,
                totalSpace: totalSpace,
                originalTree: bestTree
            )
            return .finite(profile)
        } else {
            let profile = BoundaryDomainProfile(
                parameters: parameters,
                originalTree: bestTree
            )
            return .boundary(profile)
        }
    }

    // MARK: - Tree Walk

    //
    // Dispatches on ChoiceTree node type. Returns false if the node
    // is unanalyzable (getSize, resize, bare branch). For groups,
    // detects pick patterns (group containing a .selected child) and
    // routes to walkPick; otherwise recurses into children.

    /// Recursively walks a ``ChoiceTree``, extracting independent parameters into `parameters`.
    ///
    /// For `.choice` nodes, delegates to `walkChoice`. For `.group` nodes, detects pick patterns (a group containing a `.selected` child) and routes to `walkPick`; otherwise recurses into children. Returns `false` if the tree contains structure that cannot be analyzed (getSize, resize, bare branch).
    private static func walkTree(
        _ tree: ChoiceTree,
        parameters: inout [BoundaryParameter]
    ) -> Bool {
        switch tree {
        case let .choice(value, metadata):
            return walkChoice(value: value, metadata: metadata, parameters: &parameters)

        case .just:
            return true

        case .group(_, isOpaque: true):
            return true

        case let .group(children, _):
            return walkGroup(children, parameters: &parameters)

        case let .bind(inner, bound):
            // Walk inner subtree normally; validate bound subtree without collecting
            // parameters because bound parameters depend on the inner value —
            // extracting them into covering arrays would produce invalid combinations.
            // The bound subtree is preserved in the original tree for replay.
            guard walkTree(inner, parameters: &parameters) else { return false }
            return walkTreeValidateOnly(bound)

        case let .selected(inner):
            return walkTree(inner, parameters: &parameters)

        case let .sequence(length, elements, metadata):
            return walkSequence(
                length: length,
                elements: elements,
                metadata: metadata,
                parameters: &parameters
            )

        case .getSize:
            // getSize reads the current size parameter — a fixed value during
            // any given generation run. Not a choice point.
            return true

        case let .resize(_, children):
            // resize changes the size context for its subtree. The children
            // contain concrete choices that can be walked normally.
            for child in children {
                guard walkTree(child, parameters: &parameters) else { return false }
            }
            return true

        case .branch:
            return false
        }
    }

    // MARK: - Validation-Only Walk

    //
    // Walks a subtree to check for unanalyzable nodes (getSize, resize)
    // without extracting any parameters. Used for bound subtrees in bind
    // nodes where the structure must be valid but parameters are opaque.

    private static func walkTreeValidateOnly(_ tree: ChoiceTree) -> Bool {
        switch tree {
        case .choice, .just, .getSize, .resize:
            true
        case .group(_, isOpaque: true):
            true
        case let .group(children, _):
            children.allSatisfy { walkTreeValidateOnly($0) }
        case let .bind(inner, bound):
            walkTreeValidateOnly(inner) && walkTreeValidateOnly(bound)
        case let .selected(inner):
            walkTreeValidateOnly(inner)
        case let .sequence(_, elements, _):
            elements.allSatisfy { walkTreeValidateOnly($0) }
        case let .branch(_, _, _, _, choice):
            walkTreeValidateOnly(choice)
        }
    }

    // MARK: - Choice

    //
    // Processes a single numeric choice node. Requires explicit range
    // metadata (non-explicit ranges come from size scaling and are not
    // analyzable). Computes domain size via subtractingReportingOverflow
    // to handle full-range UInt64. Small domains (< 256) enumerate all
    // values; large domains delegate to BoundaryDomainAnalysis for
    // synthetic boundary values.

    private static func walkChoice(
        value: ChoiceValue,
        metadata: ChoiceMetadata,
        parameters: inout [BoundaryParameter]
    ) -> Bool {
        guard let range = metadata.validRange, metadata.isRangeExplicit else {
            return false
        }

        let typeTag = value.tag
        let (domainSize, overflow) = range.upperBound.subtractingReportingOverflow(range.lowerBound)
        let isSmall = !overflow && domainSize < finiteDomainThreshold

        if isSmall {
            let count = domainSize + 1
            let param = BoundaryParameter(
                index: parameters.count,
                values: Array(range.lowerBound ... range.upperBound),
                domainSize: count,
                kind: .finiteChooseBits(range: range, tag: typeTag)
            )
            parameters.append(param)
        } else {
            let boundaryValues = BoundaryDomainAnalysis.computeBoundaryValues(
                min: range.lowerBound, max: range.upperBound, tag: typeTag
            )
            let param = BoundaryParameter(
                index: parameters.count,
                values: boundaryValues,
                domainSize: UInt64(boundaryValues.count),
                kind: .chooseBits(range: range, tag: typeTag)
            )
            parameters.append(param)
        }
        return true
    }

    // MARK: - Group / Pick

    //
    // A group is classified as a pick when it contains at least one
    // .selected child and all children are .selected or .branch — the
    // pattern VACTI produces with materializePicks = true.
    //
    // Pick analysis requires: ≤ 256 branches, and each branch's
    // sub-tree must contain no additional parameters (walkTree on the
    // branch's choice tree must produce zero parameters). This ensures
    // the pick is a simple multi-way selection, not a nested generator
    // tree.
    //
    // Synthetic PickTuples are created with .pure(()) generators because
    // the original branch generators are not available from the ChoiceTree.
    // The fingerprint, weight, id, and branchIDs metadata is preserved for
    // replay compatibility — CoveringArrayReplay uses these to reconstruct
    // the branch selection.

    private static func walkGroup(
        _ children: [ChoiceTree],
        parameters: inout [BoundaryParameter]
    ) -> Bool {
        if isPick(children) {
            return walkPick(children, parameters: &parameters)
        }

        for child in children {
            guard walkTree(child, parameters: &parameters) else { return false }
        }
        return true
    }

    static func isPick(_ children: [ChoiceTree]) -> Bool {
        guard !children.isEmpty else { return false }
        guard children.contains(where: \.isSelected) else { return false }
        return children.allSatisfy { child in
            child.isSelected || child.isBranch
        }
    }

    private static func walkPick(
        _ children: [ChoiceTree],
        parameters: inout [BoundaryParameter]
    ) -> Bool {
        let domainSize = UInt64(children.count)
        guard domainSize <= finiteDomainThreshold else { return false }

        for child in children {
            let unwrapped = child.unwrapped
            guard case let .branch(_, _, _, _, choice) = unwrapped else { return false }
            var subParams: [BoundaryParameter] = []
            guard walkTree(choice, parameters: &subParams) else { return false }
            guard subParams.isEmpty else { return false }
        }

        // Create synthetic PickTuples from branch metadata for replay compatibility
        var pickTuples = ContiguousArray<ReflectiveOperation.PickTuple>()
        for child in children {
            let unwrapped = child.unwrapped
            guard case let .branch(fingerprint, weight, id, _, _) = unwrapped else { return false }
            pickTuples.append(ReflectiveOperation.PickTuple(
                fingerprint: fingerprint,
                id: id,
                weight: weight,
                generator: .pure(())
            ))
        }

        let param = BoundaryParameter(
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
    // Extracts a length parameter and up to two element parameters from
    // a sequence node. The length parameter tests {0, 1, 2} (intersected
    // with the declared length range). Element analysis is capped at two
    // slots to keep the total parameter count tractable — a 4-element
    // sequence would add 1 length + 4×N element parameters, making covering
    // array generation prohibitively expensive.

    private static func walkSequence(
        length _: UInt64,
        elements: [ChoiceTree],
        metadata: ChoiceMetadata,
        parameters: inout [BoundaryParameter]
    ) -> Bool {
        guard let lengthRange = metadata.validRange, metadata.isRangeExplicit else {
            return false
        }

        var lengthValues: [UInt64] = []
        for l: UInt64 in [0, 1, 2] where lengthRange.contains(l) {
            lengthValues.append(l)
        }
        if lengthValues.isEmpty { return false }

        let lengthParam = BoundaryParameter(
            index: parameters.count,
            values: lengthValues,
            domainSize: UInt64(lengthValues.count),
            kind: .sequenceLength(lengthRange: lengthRange)
        )
        parameters.append(lengthParam)

        let maxElementSlots = min(2, Int(lengthRange.upperBound), elements.count)
        for elementIndex in 0 ..< maxElementSlots {
            guard walkElementTree(
                elements[elementIndex],
                elementIndex: elementIndex,
                parameters: &parameters
            ) else {
                return false
            }
        }

        return true
    }

    // MARK: - Element Walk

    //
    // Same as walkTree but for elements within a sequence. Rejects
    // nested sequences, getSize, resize, and bare branches — these
    // are not supported inside sequence elements. Picks within elements
    // are supported and route to the shared walkPick logic.
    //
    // walkElementChoice differs from walkChoice only in the parameter
    // kind: large-domain elements use .sequenceElement (with elementIndex)
    // instead of .chooseBits, so that BoundaryCoveringArrayReplay can
    // reconstruct the sequence structure during replay.

    private static func walkElementTree(
        _ tree: ChoiceTree,
        elementIndex: Int,
        parameters: inout [BoundaryParameter]
    ) -> Bool {
        switch tree {
        case let .choice(value, metadata):
            return walkElementChoice(
                value: value,
                metadata: metadata,
                elementIndex: elementIndex,
                parameters: &parameters
            )

        case .just:
            return true

        case .group(_, isOpaque: true):
            return true

        case let .group(children, _):
            if isPick(children) {
                return walkPick(children, parameters: &parameters)
            }
            for child in children {
                guard walkElementTree(
                    child,
                    elementIndex: elementIndex,
                    parameters: &parameters
                ) else { return false }
            }
            return true

        case let .selected(inner):
            return walkElementTree(inner, elementIndex: elementIndex, parameters: &parameters)

        case .bind:
            // Bind inside a sequence element — treat as opaque (dependent parameters)
            return true

        case .getSize:
            return true

        case .resize, .sequence, .branch:
            return false
        }
    }

    private static func walkElementChoice(
        value: ChoiceValue,
        metadata: ChoiceMetadata,
        elementIndex: Int,
        parameters: inout [BoundaryParameter]
    ) -> Bool {
        guard let range = metadata.validRange, metadata.isRangeExplicit else {
            return false
        }

        let typeTag = value.tag
        let (domainSize, overflow) = range.upperBound.subtractingReportingOverflow(range.lowerBound)
        let isSmall = !overflow && domainSize < finiteDomainThreshold

        if isSmall {
            let count = domainSize + 1
            let param = BoundaryParameter(
                index: parameters.count,
                values: Array(range.lowerBound ... range.upperBound),
                domainSize: count,
                kind: .finiteChooseBits(range: range, tag: typeTag)
            )
            parameters.append(param)
        } else {
            let boundaryValues = BoundaryDomainAnalysis.computeBoundaryValues(
                min: range.lowerBound, max: range.upperBound, tag: typeTag
            )
            let param = BoundaryParameter(
                index: parameters.count,
                values: boundaryValues,
                domainSize: UInt64(boundaryValues.count),
                kind: .sequenceElement(elementIndex: elementIndex, range: range, tag: typeTag)
            )
            parameters.append(param)
        }
        return true
    }
}
