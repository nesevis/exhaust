/// Moves element subtrees between sibling sequences in a group node.
///
/// Walks the ``ChoiceTree`` looking for group nodes with multiple `.sequence` children. For each ordered pair of sibling sequences (donor, recipient), tries moving a single element subtree from the donor into the recipient. Compatibility is determined by ``depthMaskedSiteID``: the element's root branch site (with depth suffix stripped) must match the site of existing elements in the recipient, or the recipient must be empty.
///
/// This encoder addresses local minima where a failing subtree is trapped inside a wrapper in one sibling sequence when it could live directly in another. For example, an expression wrapped in a statement in the body array could be a bare element in the args array.
///
/// Dominated by ``BindSubstitutionEncoder``: runs only after all reducible individual bind chains have converged, ensuring vertical simplification completes before lateral transplants.
struct SubtreeTransplantEncoder: ComposableEncoder {
    let name = EncoderName.transplantSiblingSubtree
    let phase = ReductionPhase.structuralDeletion

    // MARK: - State

    private var candidates: [ChoiceSequence] = []
    private var candidateIndex = 0

    // MARK: - ComposableEncoder

    func estimatedCost(
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        positionRange _: ClosedRange<Int>,
        context _: ReductionContext
    ) -> Int? {
        guard sequence.isEmpty == false else { return nil }
        var count = 0
        for element in tree.walk() {
            guard case let .group(children, _) = element.node else { continue }
            let sequenceChildCount = children.count(where: { Self.isSequenceNode($0) })
            if sequenceChildCount >= 2 { count += 1 }
        }
        return count > 0 ? count * 4 : nil
    }

    mutating func start(
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        positionRange _: ClosedRange<Int>,
        context _: ReductionContext
    ) {
        candidateIndex = 0
        candidates = Self.transplantCandidates(tree: tree, sequence: sequence)
    }

    mutating func nextProbe(lastAccepted _: Bool) -> ChoiceSequence? {
        guard candidateIndex < candidates.count else { return nil }
        let candidate = candidates[candidateIndex]
        candidateIndex += 1
        return candidate
    }

    // MARK: - Candidate Generation

    /// Builds all shortlex-improving single-element transplant candidates from the tree.
    ///
    /// For each group node with multiple sequence children, tries removing one element from a donor sequence and appending it to a sibling recipient sequence. Skips pairs where the move would violate either sequence's valid length range.
    private static func transplantCandidates(
        tree: ChoiceTree,
        sequence: ChoiceSequence
    ) -> [ChoiceSequence] {
        var candidates: [ChoiceSequence] = []

        for element in tree.walk() {
            guard case let .group(children, _) = element.node else { continue }

            let sequenceIndices = children.indices.filter { Self.isSequenceNode(children[$0]) }
            guard sequenceIndices.count >= 2 else { continue }

            for donorIndex in sequenceIndices {
                for recipientIndex in sequenceIndices where recipientIndex != donorIndex {
                    let donor = children[donorIndex].unwrapped
                    let recipient = children[recipientIndex].unwrapped

                    guard case let .sequence(_, donorElements, donorMetadata) = donor,
                          case let .sequence(_, recipientElements, recipientMetadata) = recipient
                    else { continue }
                    guard donorElements.isEmpty == false else { continue }

                    // Check donor lower bound: removing any element would produce count - 1.
                    let newDonorLength = UInt64(donorElements.count - 1)
                    if let validRange = donorMetadata.validRange,
                       newDonorLength < validRange.lowerBound {
                        continue
                    }

                    // Check recipient upper bound: adding one element would produce count + 1.
                    let newRecipientLength = UInt64(recipientElements.count + 1)
                    if let validRange = recipientMetadata.validRange,
                       newRecipientLength > validRange.upperBound {
                        continue
                    }

                    for (elementIndex, subtree) in donorElements.enumerated() {
                        guard Self.isCompatible(subtree, with: recipientElements) else { continue }

                        // Build new donor: remove element.
                        var newDonorElements = donorElements
                        newDonorElements.remove(at: elementIndex)
                        let newDonor = ChoiceTree.sequence(
                            length: newDonorLength,
                            elements: newDonorElements,
                            donorMetadata
                        )

                        // Build new recipient: append element.
                        var newRecipientElements = recipientElements
                        newRecipientElements.append(subtree)
                        let newRecipient = ChoiceTree.sequence(
                            length: newRecipientLength,
                            elements: newRecipientElements,
                            recipientMetadata
                        )

                        // Replace both sequences in the group.
                        var newChildren = children
                        newChildren[donorIndex] = newDonor
                        newChildren[recipientIndex] = newRecipient

                        var candidateTree = tree
                        candidateTree[element.fingerprint] = .group(newChildren)

                        let candidateSequence = ChoiceSequence.flatten(candidateTree)
                        if candidateSequence.shortLexPrecedes(sequence) {
                            candidates.append(candidateSequence)
                        }
                    }
                }
            }
        }

        return candidates
    }

    // MARK: - Compatibility

    /// Checks if a subtree is compatible with the existing elements of a target sequence.
    ///
    /// An element is compatible if the target is empty (wildcard) or the element's root
    /// ``depthMaskedSiteID`` matches that of any existing element in the target.
    /// Falls back to structural shape matching for branchless elements.
    private static func isCompatible(
        _ element: ChoiceTree,
        with targetElements: [ChoiceTree]
    ) -> Bool {
        if targetElements.isEmpty { return true }

        if let elementSiteID = rootDepthMaskedSiteID(element) {
            return targetElements.contains { existing in
                rootDepthMaskedSiteID(existing) == elementSiteID
            }
        }

        // No branch structure: fall back to structural shape at the root level.
        let elementKind = rootNodeKind(element)
        return targetElements.contains { existing in
            rootNodeKind(existing) == elementKind
        }
    }

    // MARK: - SiteID Extraction

    /// Extracts the depth-masked site ID from a subtree's root branch.
    ///
    /// Descends through `.selected`, `.group`, `.bind`, and `.sequence` wrappers
    /// to find the first `.branch` node, then returns `siteID / 1000`.
    private static func rootDepthMaskedSiteID(_ tree: ChoiceTree) -> UInt64? {
        switch tree.unwrapped {
        case let .branch(siteID, _, _, _, _):
            return siteID / 1000
        case let .group(children, _):
            return children.first.flatMap { rootDepthMaskedSiteID($0) }
        case let .bind(_, bound):
            return rootDepthMaskedSiteID(bound)
        case let .sequence(_, elements, _):
            return elements.first.flatMap { rootDepthMaskedSiteID($0) }
        case let .resize(_, choices):
            return choices.first.flatMap { rootDepthMaskedSiteID($0) }
        default:
            return nil
        }
    }

    // MARK: - Helpers

    private static func isSequenceNode(_ tree: ChoiceTree) -> Bool {
        if case .sequence = tree.unwrapped { return true }
        return false
    }

    /// A lightweight node kind for fallback compatibility when no branch structure is present.
    private enum RootNodeKind: Equatable {
        case choice
        case just
        case group
        case sequence
        case branch
        case other
    }

    private static func rootNodeKind(_ tree: ChoiceTree) -> RootNodeKind {
        switch tree.unwrapped {
        case .choice: .choice
        case .just: .just
        case .group: .group
        case .sequence: .sequence
        case .branch: .branch
        default: .other
        }
    }
}
