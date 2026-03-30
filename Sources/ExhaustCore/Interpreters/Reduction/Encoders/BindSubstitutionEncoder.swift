/// Substitutes a bind region's content with a deeper descendant bind region's content.
///
/// For each bind region in the sequence, finds all descendant bind regions within its bound content and constructs candidates by atomically:
/// 1. Setting the target bind's inner value to the descendant's inner value.
/// 2. Replacing the target's bound content with the descendant's bound content.
///
/// This pulls a deeper subtree up to a shallower position, reducing structural depth.
/// The property check determines whether the substitution preserves the failure.
struct BindSubstitutionEncoder: ComposableEncoder {
    var name: EncoderName { .bindSubstitution }
    let phase = ReductionPhase.structuralDeletion

    private var candidates: [ChoiceSequence] = []
    private var candidateIndex = 0

    func estimatedCost(
        sequence _: ChoiceSequence,
        tree _: ChoiceTree,
        positionRange _: ClosedRange<Int>,
        context: ReductionContext
    ) -> Int? {
        guard let bindIndex = context.bindIndex,
              bindIndex.regions.count >= 2
        else { return nil }
        // Cheap upper bound: each region with descendants contributes one probe per descendant.
        var count = 0
        for region in bindIndex.regions {
            count += Self.allDescendantRegions(of: region, in: bindIndex).count
        }
        return count > 0 ? count : nil
    }

    mutating func start(
        sequence: ChoiceSequence,
        tree _: ChoiceTree,
        positionRange _: ClosedRange<Int>,
        context: ReductionContext
    ) {
        candidateIndex = 0
        candidates = []
        guard let bindIndex = context.bindIndex else { return }
        candidates = Self.buildCandidates(
            sequence: sequence, bindIndex: bindIndex
        )
    }

    mutating func nextProbe(lastAccepted _: Bool) -> ChoiceSequence? {
        guard candidateIndex < candidates.count else { return nil }
        let candidate = candidates[candidateIndex]
        candidateIndex += 1
        return candidate
    }

    // MARK: - Candidate Construction

    /// Builds candidates for ALL bind regions in the sequence.
    ///
    /// Two strategies:
    /// 1. **Depth substitution**: for each bind region, finds descendant bind regions and constructs a candidate by promoting the descendant to the target's position.
    /// 2. **Sibling substitution**: for each pair of same-size sibling bind regions (direct children of the same parent), overwrites the target's inner+bound with the donor's content, preserving both siblings. The duplicate gives subsequent deletion passes a shortlex-smaller starting point.
    static func buildCandidates(
        sequence: ChoiceSequence,
        bindIndex: BindSpanIndex
    ) -> [ChoiceSequence] {
        var candidates: [ChoiceSequence] = []

        // Strategy 1: depth substitution (existing).
        candidates.append(
            contentsOf: buildDepthSubstitutionCandidates(
                sequence: sequence, bindIndex: bindIndex
            )
        )

        // Strategy 2: sibling substitution (new).
        candidates.append(
            contentsOf: buildSiblingSubstitutionCandidates(
                sequence: sequence, bindIndex: bindIndex
            )
        )

        return candidates
    }

    // MARK: - Depth Substitution

    /// Promotes a descendant bind region to replace an ancestor, reducing structural depth.
    private static func buildDepthSubstitutionCandidates(
        sequence: ChoiceSequence,
        bindIndex: BindSpanIndex
    ) -> [ChoiceSequence] {
        var candidates: [ChoiceSequence] = []

        for region in bindIndex.regions {
            guard region.innerRange.upperBound < sequence.count,
                  region.boundRange.upperBound < sequence.count
            else { continue }
            guard let innerEntry = sequence[region.innerRange.lowerBound].value else { continue }
            let currentDepth = innerEntry.choice.bitPattern64
            guard currentDepth > 0 else { continue }

            // Find the branch site ID inside the target's bound content.
            guard let targetBranchSiteID = firstBranchMaskedSiteID(
                in: region.boundRange, sequence: sequence
            ) else { continue }

            // Collect ALL descendant bind regions within this region's bound content.
            let descendants = allDescendantRegions(of: region, in: bindIndex)
            guard descendants.isEmpty == false else { continue }

            let innerStart = region.innerRange.lowerBound
            let innerEnd = region.innerRange.upperBound
            let boundStart = region.boundRange.lowerBound
            let boundEnd = region.boundRange.upperBound

            for descendant in descendants {
                guard descendant.boundRange.upperBound < sequence.count,
                      descendant.innerRange.lowerBound < sequence.count
                else { continue }

                // Read the descendant's inner value — this becomes the target's new inner.
                guard let descendantInner = sequence[descendant.innerRange.lowerBound].value
                else { continue }
                let descendantDepth = descendantInner.choice.bitPattern64
                guard descendantDepth < currentDepth else { continue }

                // Compatibility: inner value type must match and the branch site
                // (with depth masked out) must be the same recursive generator.
                guard descendantInner.choice.tag == innerEntry.choice.tag else { continue }
                guard let descendantBranchSiteID = firstBranchMaskedSiteID(
                    in: descendant.boundRange, sequence: sequence
                ), descendantBranchSiteID == targetBranchSiteID else { continue }

                let replacementChoice = ChoiceValue(descendantDepth, tag: innerEntry.choice.tag)
                let replacementEntry = ChoiceSequenceValue.value(
                    .init(choice: replacementChoice, validRange: innerEntry.validRange)
                )

                // Candidate = prefix + replacement inner + middle + descendant's bound + suffix.
                var candidate = ChoiceSequence()
                candidate.reserveCapacity(sequence.count)
                candidate.append(contentsOf: sequence[0 ..< innerStart])
                candidate.append(replacementEntry)
                if innerEnd + 1 < boundStart {
                    candidate.append(contentsOf: sequence[(innerEnd + 1) ..< boundStart])
                }
                candidate.append(
                    contentsOf: sequence[descendant.boundRange.lowerBound ... descendant.boundRange.upperBound]
                )
                if boundEnd + 1 < sequence.count {
                    candidate.append(contentsOf: sequence[(boundEnd + 1)...])
                }

                if candidate.shortLexPrecedes(sequence) {
                    candidates.append(candidate)
                }
            }
        }

        return candidates
    }

    // MARK: - Sibling Substitution

    /// For each pair of sibling bind regions, overwrites the target's inner+bound with the donor's inner+bound, preserving both siblings in the sequence.
    ///
    /// The result has two copies of the donor's content. The duplicate gives subsequent deletion passes a shortlex-smaller starting point from which to remove one copy.
    private static func buildSiblingSubstitutionCandidates(
        sequence: ChoiceSequence,
        bindIndex: BindSpanIndex
    ) -> [ChoiceSequence] {
        var candidates: [ChoiceSequence] = []

        for parent in bindIndex.regions {
            let children = directChildRegions(of: parent, in: bindIndex)
            guard children.count >= 2 else { continue }

            for target in children {
                for donor in children {
                    guard target.bindSpanRange != donor.bindSpanRange else { continue }
                    guard target.innerRange.upperBound < sequence.count,
                          target.boundRange.upperBound < sequence.count,
                          donor.innerRange.lowerBound < sequence.count,
                          donor.boundRange.upperBound < sequence.count
                    else { continue }

                    // Both siblings must have the same inner+bound size for a clean
                    // overwrite — different sizes would shift all subsequent positions.
                    let targetContentSize = (target.innerRange.lowerBound ... target.boundRange.upperBound).count
                    let donorContentSize = (donor.innerRange.lowerBound ... donor.boundRange.upperBound).count
                    guard targetContentSize == donorContentSize else { continue }

                    // Compatibility: inner value tags must match.
                    guard let targetInner = sequence[target.innerRange.lowerBound].value,
                          let donorInner = sequence[donor.innerRange.lowerBound].value,
                          targetInner.choice.tag == donorInner.choice.tag
                    else { continue }

                    // Build candidate: overwrite target's inner+bound with donor's content.
                    // Everything else (bind markers, donor's original, suffix) is unchanged.
                    var candidate = ChoiceSequence()
                    candidate.reserveCapacity(sequence.count)
                    candidate.append(contentsOf: sequence[0 ..< target.innerRange.lowerBound])
                    candidate.append(contentsOf: sequence[donor.innerRange.lowerBound ... donor.boundRange.upperBound])
                    if target.boundRange.upperBound + 1 < sequence.count {
                        candidate.append(contentsOf: sequence[(target.boundRange.upperBound + 1)...])
                    }

                    if candidate.shortLexPrecedes(sequence) {
                        candidates.append(candidate)
                    }
                }
            }
        }

        return candidates
    }

    // MARK: - Compatibility

    /// Returns the ``ChoiceSequenceValue/Branch/depthMaskedSiteID`` of the first branch entry within the given range, or `nil` if no branch is found.
    private static func firstBranchMaskedSiteID(
        in range: ClosedRange<Int>,
        sequence: ChoiceSequence
    ) -> UInt64? {
        var position = range.lowerBound
        while position <= range.upperBound {
            if case let .branch(branch) = sequence[position] {
                return branch.depthMaskedSiteID
            }
            position += 1
        }
        return nil
    }

    // MARK: - Child Discovery

    /// Finds ALL descendant bind regions within the given parent's bound content.
    static func allDescendantRegions(
        of parent: BindSpanIndex.BindRegion,
        in bindIndex: BindSpanIndex
    ) -> [BindSpanIndex.BindRegion] {
        var descendants: [BindSpanIndex.BindRegion] = []
        for region in bindIndex.regions {
            if region.bindSpanRange == parent.bindSpanRange { continue }
            if parent.boundRange.contains(region.bindSpanRange.lowerBound) {
                descendants.append(region)
            }
        }
        return descendants
    }

    /// Finds bind regions that are direct children of the outermost bind.
    static func directChildRegions(
        bindIndex: BindSpanIndex
    ) -> [BindSpanIndex.BindRegion] {
        guard let outermost = bindIndex.regions.first else { return [] }
        return directChildRegions(of: outermost, in: bindIndex)
    }

    /// Finds bind regions that are direct children of the given parent region.
    static func directChildRegions(
        of parent: BindSpanIndex.BindRegion,
        in bindIndex: BindSpanIndex
    ) -> [BindSpanIndex.BindRegion] {
        let parentDepth = bindIndex.bindDepth(at: parent.boundRange.lowerBound)
        var children: [BindSpanIndex.BindRegion] = []
        for region in bindIndex.regions {
            if region.bindSpanRange == parent.bindSpanRange { continue }
            if parent.boundRange.contains(region.bindSpanRange.lowerBound)
                && bindIndex.bindDepth(at: region.bindSpanRange.lowerBound) == parentDepth + 1
            {
                children.append(region)
            }
        }
        return children
    }
}
