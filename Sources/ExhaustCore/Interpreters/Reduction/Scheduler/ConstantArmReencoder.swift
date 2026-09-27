//
//  ConstantArmReencoder.swift
//  Exhaust
//

// MARK: - Constant Arm Re-encoding

/// Moves the initial counterexample's constant arms into a sibling arm that reproduces their value, so reduction can go below them.
///
/// A `.just` arm flattens to one entry, so no sibling encoding of its value is shortlex-smaller and the reducer never leaves it. Re-encoding keeps the output unchanged. Every reproducible constant arm at the pick site is then excluded, including unselected arms, so a later pivot cannot restore the opaque encoding.
///
/// Every level of a recursive generator shares its pick fingerprint, so a site under a pick with the same fingerprint is skipped, and sibling reflection stops at that fingerprint.
///
/// - Complexity: O(*n*) without reproducible constant arms. Otherwise performs two exact materializations and up to one first-match reflection per sibling of each constant arm.
enum ConstantArmReencoder {
    /// Returns the normalized sequence and the constant-arm pivots excluded at its pick sites, or nil when no arm can be re-encoded.
    static func reencode(
        sequence: ChoiceSequence,
        gen: AnyGenerator
    ) -> (sequence: ChoiceSequence, tree: ChoiceTree, excludedPivots: Set<ExcludedPivot>)? {
        let eligibleIndices = eligiblePickIndices(in: sequence)
        guard eligibleIndices.isEmpty == false else {
            return nil
        }

        let capture = ConstantArmCapture()
        var captureContext = Materializer.Context(prefix: sequence, mode: .exact, skipTree: true, collectDecodingReport: false)
        captureContext.constantArmCapture = capture
        guard case .success = Materializer.materializeAny(gen, context: captureContext) else {
            return nil
        }

        var candidate = sequence
        var excludedPivots: Set<ExcludedPivot> = []
        // Descending, so a splice never shifts a site still to be processed.
        let sites = capture.sites
            .filter { eligibleIndices.contains($0.branchIndex) }
            .sorted { $0.branchIndex > $1.branchIndex }
        var siteIndex = 0
        while siteIndex < sites.count {
            let site = sites[siteIndex]
            siteIndex += 1
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
                    constantBranchID: constantChoice.id
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

        guard case let .success(_, freshTree, _) = Materializer.materializeAny(
            gen,
            context: .init(prefix: candidate, mode: .exact, materializePicks: true, collectDecodingReport: false)
        ) else {
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
        var context = ReflectionContext.root
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
