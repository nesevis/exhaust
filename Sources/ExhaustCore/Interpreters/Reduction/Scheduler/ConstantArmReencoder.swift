//
//  ConstantArmReencoder.swift
//  Exhaust
//

// MARK: - Constant Arm Re-encoding

/// Moves the initial counterexample's constant arms into a sibling arm that reproduces their value, so reduction can go below them.
///
/// A `.just` arm flattens to one entry, so no sibling encoding of its value is shortlex-smaller and the reducer never leaves it. Re-encoding keeps the output unchanged. Every reproducible constant arm at the pick site is then excluded, including unselected arms, so a later pivot cannot restore the opaque encoding.
///
/// An exclusion holds only for the arm domains it was classified against. Picks written at one source location share a fingerprint but receive their arms at runtime, from helper arguments or upstream bind values, so each exclusion carries the site's ``ExcludedPivot/armDomainSignature(of:)``.
///
/// Every level of a recursive generator shares its pick fingerprint, so a site under a pick with the same fingerprint is skipped, and sibling reflection stops at that fingerprint.
///
/// Sibling reflection runs in pick-arm context, where nodes that would echo the target rebuild it instead, and the rewrite is abandoned unless replaying it produces the original output: reflection can decompose values its forward pass cannot produce.
///
/// - Complexity: O(*n*) without reproducible constant arms. Otherwise performs two exact materializations and up to one first-match reflection per sibling of each constant arm.
enum ConstantArmReencoder {
    /// Returns the normalized sequence and the constant-arm pivots excluded at its pick sites, or nil when no arm can be re-encoded.
    ///
    /// - Parameters:
    ///   - sequence: The counterexample's choice sequence.
    ///   - tree: The tree `sequence` flattens from, with unselected branches materialized. Arm domain signatures are read from its pick nodes; a site without a matching pick node is left unchanged.
    ///   - gen: The generator that produced the counterexample.
    static func reencode(
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        gen: AnyGenerator
    ) -> (sequence: ChoiceSequence, tree: ChoiceTree, excludedPivots: Set<ExcludedPivot>)? {
        let eligibleIndices = eligiblePickIndices(in: sequence)
        guard eligibleIndices.isEmpty == false else {
            return nil
        }

        let capture = ConstantArmCapture()
        var captureContext = Materializer.Context(prefix: sequence, mode: .exact, skipTree: true, collectDecodingReport: false)
        captureContext.constantArmCapture = capture
        guard case let .success(originalOutput, _, _) = Materializer.materializeAny(gen, context: captureContext) else {
            return nil
        }

        var candidate = sequence
        var excludedPivots: Set<ExcludedPivot> = []
        // Descending, so a splice never shifts a site still to be processed.
        let sites = capture.sites
            .filter { eligibleIndices.contains($0.branchIndex) }
            .sorted { $0.branchIndex > $1.branchIndex }
        guard sites.isEmpty == false else {
            return nil
        }
        let pickMetadataByBranchIndex = pickMetadataByBranchIndex(in: ChoiceGraph.build(from: tree))
        var siteIndex = 0
        while siteIndex < sites.count {
            let site = sites[siteIndex]
            siteIndex += 1
            guard let pickMetadata = pickMetadataByBranchIndex[site.branchIndex] else {
                continue
            }
            let armDomainSignature = ExcludedPivot.armDomainSignature(of: pickMetadata)
            var choiceIndex = 0
            while choiceIndex < site.choices.count {
                let constantIndex = choiceIndex
                let constantChoice = site.choices[constantIndex]
                choiceIndex += 1
                guard let constantValue = constantValue(of: constantChoice.generator),
                      let (sibling, armEntries) = reproducingSibling(
                          for: site,
                          constantIndex: constantIndex,
                          constantValue: constantValue
                      )
                else {
                    continue
                }
                excludedPivots.insert(ExcludedPivot(
                    fingerprint: constantChoice.fingerprint,
                    constantBranchID: constantChoice.id,
                    armDomainSignature: armDomainSignature
                ))
                guard constantIndex == site.selectedIndex,
                      let bodyIndex = constantBodyIndex(in: candidate, afterBranchAt: site.branchIndex)
                else {
                    continue
                }
                candidate.replaceSubrange(bodyIndex ... bodyIndex, with: armEntries)
                candidate[site.branchIndex] = .branch(.init(
                    id: sibling.id,
                    branchCount: UInt64(site.choices.count),
                    fingerprint: sibling.fingerprint
                ))
            }
        }
        guard excludedPivots.isEmpty == false else {
            return nil
        }

        // Reflection can report the requested value without producing it, so the rewrite stands only if replaying it produces the original output.
        guard case let .success(reencodedOutput, freshTree, _) = Materializer.materializeAny(
            gen,
            context: .init(prefix: candidate, mode: .exact, materializePicks: true, collectDecodingReport: false)
        ), reproduces(reencodedOutput, originalOutput) else {
            return nil
        }
        return (ChoiceSequence(freshTree), freshTree, excludedPivots)
    }

    /// Continuation steps ``constantValue(of:)`` follows before treating a generator as not constant. Bounds the walk, since each step runs a user continuation.
    private static let maximumConstantSteps = 8

    /// The value a choice-free generator produces, found by following `.just` continuations to `.pure`, or nil.
    static func constantValue(of generator: AnyGenerator) -> Any? {
        var current = generator
        var steps = 0
        while steps < maximumConstantSteps {
            steps += 1
            switch current {
                case let .pure(value):
                    return value
                case let .impure(.just(value), continuation):
                    guard let next = try? continuation(value) else {
                        return nil
                    }
                    current = next
                default:
                    return nil
            }
        }
        return nil
    }

    // MARK: - Private Helpers

    /// Branch-marker indices of picks that sit under no pick with the same fingerprint.
    private static func eligiblePickIndices(in sequence: ChoiceSequence) -> Set<Int> {
        var indices: Set<Int> = []
        // A pick's group opens just before its branch marker, so the marker tags the innermost open group.
        var openGroupFingerprints: [UInt64?] = []
        var index = 0
        while index < sequence.count {
            switch sequence[index] {
                case .group(true):
                    openGroupFingerprints.append(nil)
                case .group(false):
                    _ = openGroupFingerprints.popLast()
                case let .branch(branch):
                    let isRecursive = openGroupFingerprints.dropLast().contains(branch.fingerprint)
                    if openGroupFingerprints.isEmpty == false {
                        openGroupFingerprints[openGroupFingerprints.count - 1] = branch.fingerprint
                    }
                    if branch.branchCount >= 2, isRecursive == false {
                        indices.insert(index)
                    }
                default:
                    break
            }
            index += 1
        }
        return indices
    }

    /// Active picks keyed by the sequence index of their branch marker, which directly follows the pick's opening group marker.
    private static func pickMetadataByBranchIndex(in graph: ChoiceGraph) -> [Int: PickMetadata] {
        var metadataByBranchIndex: [Int: PickMetadata] = [:]
        var liveIndex = 0
        while liveIndex < graph.liveNodeIDs.count {
            let node = graph.nodes[graph.liveNodeIDs[liveIndex]]
            liveIndex += 1
            guard case let .pick(metadata) = node.kind, let range = node.positionRange else {
                continue
            }
            metadataByBranchIndex[range.lowerBound + 1] = metadata
        }
        return metadataByBranchIndex
    }

    /// The constant's entry after a branch marker, past the pair-group marker a non-pure continuation inserts.
    private static func constantBodyIndex(in sequence: ChoiceSequence, afterBranchAt branchIndex: Int) -> Int? {
        var index = branchIndex + 1
        if index < sequence.count, case .group(true) = sequence[index] {
            index += 1
        }
        guard index < sequence.count, case .just = sequence[index] else {
            return nil
        }
        return index
    }

    /// The first sibling, in declaration order, whose reflection reproduces the constant.
    ///
    /// Reflects through the arm, because reflecting through the pick returns the constant arm itself when it is declared first. A decomposition counts only if its value equals the constant: backward maps can decompose values they cannot produce.
    private static func reproducingSibling(
        for site: ConstantArmSite,
        constantIndex: Int,
        constantValue: Any
    ) -> (sibling: ReflectiveOperation.PickTuple, armEntries: ChoiceSequence)? {
        var context = ReflectionContext.root.enteringPickArm()
        context.stopsAtFirstMatchingArm = true
        context.excludedPickFingerprint = site.choices[constantIndex].fingerprint
        var choiceIndex = 0
        while choiceIndex < site.choices.count {
            let siblingIndex = choiceIndex
            let sibling = site.choices[siblingIndex]
            choiceIndex += 1
            guard siblingIndex != constantIndex,
                  self.constantValue(of: sibling.generator) == nil
            else {
                continue
            }
            guard let outcomes = try? Interpreters.reflectRecursive(
                sibling.generator,
                onFinalOutput: constantValue,
                context: context
            ), let armTree = outcomes.first(where: { reproduces($0.value, constantValue) })?.path.first else {
                continue
            }
            return (sibling, ChoiceSequence.flatten(armTree))
        }
        return nil
    }

    /// Value equality, falling back to structural comparison for values that are not `Equatable`. Unlike pick reflection, which accepts a `BitPatternConvertible` value that lies in the arm's range, this requires the reflected value to equal the constant.
    private static func reproduces(_ reflected: Any, _ constant: Any) -> Bool {
        if let reflectedEquatable = reflected as? any Equatable,
           let constantEquatable = constant as? any Equatable
        {
            return reflectedEquatable.isEqual(constantEquatable)
        }
        return structurallyEqual(reflected, constant)
    }
}

// MARK: - Supporting Types

/// The pivot back to a re-encoded pick site's constant arm.
struct ExcludedPivot: Hashable {
    let fingerprint: UInt64
    let constantBranchID: UInt64
    /// The ``armDomainSignature(of:)`` of the site the constant was classified at. A pick at the same source location with different arm domains is a different site: its constant may have no sibling representation.
    let armDomainSignature: Int

    /// Hashes the domains each arm of a pick draws from, ignoring the values drawn.
    ///
    /// Unselected arms are refilled on every rebuild, often with empty sequences, and a signature that moved with the fill would drop the exclusion at random. Each arm therefore contributes the set of its leaf ranges, sequence length ranges, nested pick sites, and bind sites, without values. Sequence elements, bound subtrees, and nested pick arms are not entered, since whether they exist depends on values drawn inside the arm.
    ///
    /// - Note: A constant's value and a transform's captured values are not in the tree, so two sites that differ only in those share a signature.
    static func armDomainSignature(of metadata: PickMetadata) -> Int {
        var hasher = Hasher()
        hasher.combine(metadata.fingerprint)
        var elementIndex = 0
        while elementIndex < metadata.branchElements.count {
            let element = metadata.branchElements[elementIndex]
            elementIndex += 1
            guard case let .branch(branch) = element else {
                continue
            }
            var domains: Set<ArmDomain> = []
            collectArmDomains(in: branch.choice, into: &domains)
            hasher.combine(branch.id)
            hasher.combine(domains)
        }
        return hasher.finalize()
    }

    private static func collectArmDomains(in tree: ChoiceTree, into domains: inout Set<ArmDomain>) {
        switch tree {
            case let .choice(value, metadata):
                domains.insert(.leaf(
                    tag: value.tag,
                    validRange: metadata.validRange,
                    isRangeExplicit: metadata.isRangeExplicit
                ))
            case .just:
                domains.insert(.constant)
            case let .sequence(_, metadata):
                domains.insert(.sequenceLength(
                    validRange: metadata.validRange,
                    isRangeExplicit: metadata.isRangeExplicit
                ))
            case let .branch(branch):
                domains.insert(.nestedPick(fingerprint: branch.fingerprint, branchCount: branch.branchCount))
            case let .group(children, _, _):
                collectArmDomains(in: children, into: &domains)
            case .getSize:
                break
            case let .resize(_, choices):
                collectArmDomains(in: choices, into: &domains)
            case let .bind(fingerprint, inner, _):
                domains.insert(.bind(fingerprint: fingerprint))
                collectArmDomains(in: inner, into: &domains)
        }
    }

    private static func collectArmDomains(in trees: [ChoiceTree], into domains: inout Set<ArmDomain>) {
        var index = 0
        while index < trees.count {
            collectArmDomains(in: trees[index], into: &domains)
            index += 1
        }
    }
}

/// One domain an arm draws from, as ``ExcludedPivot/armDomainSignature(of:)`` records it.
private enum ArmDomain: Hashable {
    case leaf(tag: TypeTag, validRange: ClosedRange<UInt64>?, isRangeExplicit: Bool)
    case sequenceLength(validRange: ClosedRange<UInt64>?, isRangeExplicit: Bool)
    case nestedPick(fingerprint: UInt64, branchCount: UInt64)
    case bind(fingerprint: UInt64)
    case constant
}

/// An active pick recorded during the capture replay.
struct ConstantArmSite {
    let branchIndex: Int
    let choices: ContiguousArray<ReflectiveOperation.PickTuple>
    let selectedIndex: Int
}

/// Collects active pick sites during one exact replay. A class, so the materializer can append through its by-value context.
final class ConstantArmCapture {
    private(set) var sites: [ConstantArmSite] = []

    /// Records a non-backtracking pick whose constant arms may need re-encoding or exclusion.
    func record(
        branchIndex: Int,
        choices: ContiguousArray<ReflectiveOperation.PickTuple>,
        selectedIndex: Int
    ) {
        guard choices.count >= 2,
              choices[0].isBacktrack == false,
              choices[0].isFailable == false
        else {
            return
        }
        sites.append(ConstantArmSite(
            branchIndex: branchIndex,
            choices: choices,
            selectedIndex: selectedIndex
        ))
    }
}
