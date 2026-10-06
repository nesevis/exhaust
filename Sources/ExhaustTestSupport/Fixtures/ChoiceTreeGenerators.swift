import ExhaustCore

/// Generates choice trees directly, for graph and reducer tests that need tree shapes no user generator would produce on demand.
package enum ChoiceTreeGenerators {
    /// Scalar arrays are the shape the partial builder collapses; binds, picks, and mixed arrays are the shapes it must leave intact around them.
    package static let trees: Generator<ChoiceTree> = Gen.recursive(base: leaves, depthRange: 0 ... 4) { recurse, _ in
        let scalarArrays = Gen.arrayOf(leaves, within: 0 ... 24).map { Self.sequence($0) }
        let binds = Gen.zip(Gen.choose(in: UInt64(1) ... 1000), leaves, recurse()).map { fingerprint, inner, bound in
            ChoiceTree.bind(fingerprint: fingerprint, inner: inner, bound: bound)
        }
        let groups = Gen.arrayOf(recurse(), within: 1 ... 3).map { ChoiceTree.group($0) }
        let mixedArrays = Gen.arrayOf(recurse(), within: 0 ... 3).map { Self.sequence($0) }
        let arms: Generator<[ChoiceTree]> = Gen.arrayOf(recurse(), within: 2 ... 3)
        let selections: Generator<Int> = Gen.choose(in: 0 ... 2)
        let picks: Generator<ChoiceTree> = Gen.zip(arms, selections).map { arms, selected in
            Self.pick(arms: arms, selected: selected % arms.count)
        }
        let choices: [(weight: Int, generator: Generator<ChoiceTree>)] = [
            (1, leaves),
            (2, scalarArrays),
            (2, binds),
            (1, groups),
            (1, mixedArrays),
            (1, picks),
        ]
        return Gen.pick(choices: choices)
    }

    /// Covers the shapes reducer scope queries discriminate on, for differential tests against eager references.
    ///
    /// The root is a zip of one to five subtrees, so sibling sequences, cross-slot pairs, and independent pick families appear in most samples. Leaves mix signed, unsigned, floating, character, and control tags, sit on and off their reduction targets, and sometimes carry explicit ranges. Sequences are either homogeneous scalar runs, which homogeneous redistribution pairs, or mixed subtrees, and carry no length constraint, an exact one, a loose upper bound, or a deletion floor. Picks are weighted heavily and draw from two fingerprints, so most trees hold self-similar families, often two, with picks nested inside same-fingerprint picks for descendant promotion. Non-pick groups build zips.
    package static let scopeTrees: Generator<ChoiceTree> = Gen.arrayOf(scopeSubtrees, within: 1 ... 5).map { ChoiceTree.group($0) }

    /// Starts at depth one so a zip root's slots are rarely bare leaves, which would leave sequence and pick scopes without partners.
    private static let scopeSubtrees: Generator<ChoiceTree> = Gen.recursive(base: scopeLeaves, depthRange: 1 ... 4) { recurse, _ in
        let homogeneousArrays = Gen.zip(
            Gen.choose(from: scopeLeafTags),
            Gen.arrayOf(scopeLeafShapes, within: 0 ... 8),
            lengthConstraintModes
        ).map { tag, shapes, constraintMode in
            Self.constrainedSequence(
                shapes.map { offset, rangeMode in Self.scopeLeaf(tag: tag, offset: offset, rangeMode: rangeMode) },
                constraintMode: constraintMode
            )
        }
        let mixedArrays = Gen.zip(Gen.arrayOf(recurse(), within: 0 ... 4), lengthConstraintModes).map { elements, constraintMode in
            Self.constrainedSequence(elements, constraintMode: constraintMode)
        }
        let zips = Gen.arrayOf(recurse(), within: 2 ... 4).map { ChoiceTree.group($0) }
        // Subtree inners place sequences and picks on the controlling side of a dependency edge, which migration and promotion gates must observe.
        let inners = Gen.pick(choices: [(1, scopeLeaves), (1, recurse())])
        let binds = Gen.zip(Gen.choose(in: UInt64(1) ... 1000), inners, recurse()).map { fingerprint, inner, bound in
            ChoiceTree.bind(fingerprint: fingerprint, inner: inner, bound: bound)
        }
        let picks = Gen.zip(
            Gen.choose(from: [UInt64(7), 8]),
            Gen.arrayOf(recurse(), within: 2 ... 3),
            Gen.choose(in: 0 ... 2)
        ).map { fingerprint, arms, selected in
            ChoiceTree.pickSite(fingerprint: fingerprint, selected: selected % arms.count, branches: arms)
        }
        let choices: [(weight: Int, generator: Generator<ChoiceTree>)] = [
            (1, scopeLeaves),
            (2, homogeneousArrays),
            (1, mixedArrays),
            (2, zips),
            (2, binds),
            (4, picks),
        ]
        return Gen.pick(choices: choices)
    }

    private static let leaves = Gen.choose(in: UInt64(0) ... 10).map { ChoiceTree.uint64($0, in: 0 ... 10) }

    private static let scopeLeafTags: [TypeTag] = [.uint64, .uint32, .uint8, .int64, .int32, .int8, .double, .character, .depthControl, .laneControl]

    /// Offsets from each tag's simplest value, wide enough that stalled magnitudes share factors for relation pairs, paired with a range mode: zero leaves the full type width, one adds an explicit range around the value.
    private static let scopeLeafShapes = Gen.zip(Gen.choose(in: -12 ... 12), Gen.choose(in: 0 ... 1))

    private static let scopeLeaves = Gen.zip(Gen.choose(from: scopeLeafTags), scopeLeafShapes).map { tag, shape in
        Self.scopeLeaf(tag: tag, offset: shape.0, rangeMode: shape.1)
    }

    /// Zero is unconstrained, one is exact, two allows growth, and three sets a deletion floor below the current length.
    private static let lengthConstraintModes = Gen.choose(in: 0 ... 3)

    // MARK: - Helpers

    private static func sequence(_ elements: [ChoiceTree]) -> ChoiceTree {
        let count = UInt64(elements.count)
        return .sequence(elements: elements, metadata: .init(validRange: count ... count, isRangeExplicit: true))
    }

    private static func pick(arms: [ChoiceTree], selected: Int) -> ChoiceTree {
        let branches: [ChoiceTree] = arms.enumerated().map { index, arm in
            .branch(
                fingerprint: 7,
                weight: 1,
                id: UInt64(index),
                branchCount: UInt64(arms.count),
                choice: arm,
                isSelected: index == selected
            )
        }
        return .group(branches)
    }

    /// Clamps the offset into the tag's bit-pattern range, so unsigned and control tags fold negative offsets onto zero.
    private static func scopeLeaf(tag: TypeTag, offset: Int, rangeMode: Int) -> ChoiceTree {
        guard tag.isFloatingPoint == false else {
            return .choice(ChoiceValue(Double(offset) / 2, tag: tag), .init(validRange: nil))
        }
        let typeRange = tag.bitPatternRange
        let simplest = tag.simplestBitPattern
        let magnitude = UInt64(offset.magnitude)
        let shifted = switch offset < 0 {
            case true:
                simplest >= magnitude ? simplest - magnitude : typeRange.lowerBound
            case false:
                simplest + magnitude
        }
        let pattern = min(max(shifted, typeRange.lowerBound), typeRange.upperBound)
        guard rangeMode == 1 else {
            return .choice(ChoiceValue(pattern, tag: tag), .init(validRange: nil))
        }
        let lowerBound = max(typeRange.lowerBound, pattern >= 3 ? pattern - 3 : 0)
        let upperBound = min(typeRange.upperBound, pattern + 3)
        return .choice(ChoiceValue(pattern, tag: tag), .init(validRange: lowerBound ... upperBound, isRangeExplicit: true))
    }

    private static func constrainedSequence(_ elements: [ChoiceTree], constraintMode: Int) -> ChoiceTree {
        let count = UInt64(elements.count)
        let lengthConstraint: ClosedRange<UInt64>? = switch constraintMode {
            case 1:
                count ... count
            case 2:
                0 ... count + 2
            case 3:
                count / 2 ... count + 1
            default:
                nil
        }
        return .sequence(elements: elements, metadata: .init(validRange: lengthConstraint, isRangeExplicit: lengthConstraint != nil))
    }
}
