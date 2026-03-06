//
//  ChoiceTreeAnalysis.swift
//  Exhaust
//

/// Unified coverage analysis that walks a VACTI-generated `ChoiceTree` to extract
/// parameter domains for covering array construction.
///
/// This replaces the recursive generator walk in `FiniteDomainAnalysis` and
/// `BoundaryDomainAnalysis`. By running the generator through VACTI with
/// `materializePicks = true`, the analysis sees through opaque bind chains
/// that the recursive walker cannot follow.
public enum ChoiceTreeAnalysis {

    public enum AnalysisResult {
        case finite(FiniteDomainProfile)
        case boundary(BoundaryDomainProfile)
    }

    private static let maxParameterCount = 20
    private static let finiteDomainThreshold: UInt64 = 256

    private static let seeds: [UInt64] = [
        0x600D_F00D_600D_E665, // good food good eggs
        0xF165_BEEF_C0D5_A6E0, // figs beef cod sage
        0xF0CC_AC1A_C0FF_EE50, // focaccia coffees
    ]

    /// Analyzes a generator by running it through VACTI and walking the resulting ChoiceTree.
    ///
    /// Returns `.finite` if all parameters have small domains (≤256 values),
    /// `.boundary` if some parameters need boundary value synthesis, or `nil`
    /// if the generator is not analyzable (e.g., uses getSize/resize).
    ///
    /// Tries multiple seeds to maximize element coverage for sequences.
    public static func analyze<Output>(_ gen: ReflectiveGenerator<Output>) -> AnalysisResult? {
        var bestParameters: [BoundaryParameter]?

        for seed in seeds {
            var interpreter = ValueAndChoiceTreeInterpreter(
                gen,
                materializePicks: true,
                seed: seed,
                maxRuns: 1,
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
            }

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
        guard parameters.count <= maxParameterCount else {
            return nil
        }

        let allFinite = parameters.allSatisfy { param in
            switch param.kind {
            case .finiteChooseBits, .pick:
                return true
            case .chooseBits, .sequenceLength, .sequenceElement:
                return false
            }
        }

        if allFinite {
            let finiteParams = parameters.enumerated().map { i, param -> FiniteParameter in
                switch param.kind {
                case let .finiteChooseBits(range, tag):
                    return FiniteParameter(index: i, domainSize: param.domainSize, kind: .chooseBits(range: range, tag: tag))
                case let .pick(choices):
                    return FiniteParameter(index: i, domainSize: param.domainSize, kind: .pick(choices: choices))
                default:
                    fatalError("unreachable: allFinite check passed")
                }
            }
            var totalSpace: UInt64 = 1
            for param in finiteParams {
                let (product, overflow) = totalSpace.multipliedReportingOverflow(by: param.domainSize)
                if overflow { totalSpace = .max; break }
                totalSpace = product
            }
            return .finite(FiniteDomainProfile(parameters: finiteParams, totalSpace: totalSpace))
        } else {
            return .boundary(BoundaryDomainProfile(parameters: parameters))
        }
    }

    // MARK: - Tree Walk

    private static func walkTree(
        _ tree: ChoiceTree,
        parameters: inout [BoundaryParameter],
    ) -> Bool {
        switch tree {
        case let .choice(value, metadata):
            return walkChoice(value: value, metadata: metadata, parameters: &parameters)

        case .just:
            return true

        case let .group(children):
            return walkGroup(children, parameters: &parameters)

        case let .selected(inner):
            return walkTree(inner, parameters: &parameters)

        case let .sequence(length, elements, metadata):
            return walkSequence(length: length, elements: elements, metadata: metadata, parameters: &parameters)

        case .getSize, .resize:
            return false

        case .branch:
            return false
        }
    }

    // MARK: - Choice

    private static func walkChoice(
        value: ChoiceValue,
        metadata: ChoiceMetadata,
        parameters: inout [BoundaryParameter],
    ) -> Bool {
        guard let range = metadata.validRange, metadata.isRangeExplicit else {
            return false
        }

        let tag = value.tag
        let (domainSize, overflow) = range.upperBound.subtractingReportingOverflow(range.lowerBound)
        let isSmall = !overflow && domainSize < finiteDomainThreshold

        if isSmall {
            let count = domainSize + 1
            let param = BoundaryParameter(
                index: parameters.count,
                values: Array(range.lowerBound ... range.upperBound),
                domainSize: count,
                kind: .finiteChooseBits(range: range, tag: tag)
            )
            parameters.append(param)
        } else {
            let boundaryValues = BoundaryDomainAnalysis.computeBoundaryValues(min: range.lowerBound, max: range.upperBound, tag: tag)
            let param = BoundaryParameter(
                index: parameters.count,
                values: boundaryValues,
                domainSize: UInt64(boundaryValues.count),
                kind: .chooseBits(range: range, tag: tag)
            )
            parameters.append(param)
        }
        return true
    }

    // MARK: - Group / Pick

    private static func walkGroup(
        _ children: [ChoiceTree],
        parameters: inout [BoundaryParameter],
    ) -> Bool {
        if isPick(children) {
            return walkPick(children, parameters: &parameters)
        }

        for child in children {
            guard walkTree(child, parameters: &parameters) else { return false }
        }
        return true
    }

    private static func isPick(_ children: [ChoiceTree]) -> Bool {
        guard !children.isEmpty else { return false }
        guard children.contains(where: \.isSelected) else { return false }
        return children.allSatisfy { child in
            child.isSelected || child.isBranch
        }
    }

    private static func walkPick(
        _ children: [ChoiceTree],
        parameters: inout [BoundaryParameter],
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
            guard case let .branch(siteID, weight, id, _, _) = unwrapped else { return false }
            pickTuples.append(ReflectiveOperation.PickTuple(
                siteID: siteID,
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

    private static func walkSequence(
        length: UInt64,
        elements: [ChoiceTree],
        metadata: ChoiceMetadata,
        parameters: inout [BoundaryParameter],
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
            guard walkElementTree(elements[elementIndex], elementIndex: elementIndex, parameters: &parameters) else {
                return false
            }
        }

        return true
    }

    // MARK: - Element Walk

    private static func walkElementTree(
        _ tree: ChoiceTree,
        elementIndex: Int,
        parameters: inout [BoundaryParameter],
    ) -> Bool {
        switch tree {
        case let .choice(value, metadata):
            return walkElementChoice(value: value, metadata: metadata, elementIndex: elementIndex, parameters: &parameters)

        case .just:
            return true

        case let .group(children):
            if isPick(children) {
                return walkPick(children, parameters: &parameters)
            }
            for child in children {
                guard walkElementTree(child, elementIndex: elementIndex, parameters: &parameters) else { return false }
            }
            return true

        case let .selected(inner):
            return walkElementTree(inner, elementIndex: elementIndex, parameters: &parameters)

        case .getSize, .resize, .sequence, .branch:
            return false
        }
    }

    private static func walkElementChoice(
        value: ChoiceValue,
        metadata: ChoiceMetadata,
        elementIndex: Int,
        parameters: inout [BoundaryParameter],
    ) -> Bool {
        guard let range = metadata.validRange, metadata.isRangeExplicit else {
            return false
        }

        let tag = value.tag
        let (domainSize, overflow) = range.upperBound.subtractingReportingOverflow(range.lowerBound)
        let isSmall = !overflow && domainSize < finiteDomainThreshold

        if isSmall {
            let count = domainSize + 1
            let param = BoundaryParameter(
                index: parameters.count,
                values: Array(range.lowerBound ... range.upperBound),
                domainSize: count,
                kind: .finiteChooseBits(range: range, tag: tag)
            )
            parameters.append(param)
        } else {
            let boundaryValues = BoundaryDomainAnalysis.computeBoundaryValues(min: range.lowerBound, max: range.upperBound, tag: tag)
            let param = BoundaryParameter(
                index: parameters.count,
                values: boundaryValues,
                domainSize: UInt64(boundaryValues.count),
                kind: .sequenceElement(elementIndex: elementIndex, range: range, tag: tag)
            )
            parameters.append(param)
        }
        return true
    }
}
