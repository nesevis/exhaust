//
//  ChoiceTree+RepresentationComparison.swift
//  ExhaustTests
//

@testable import ExhaustCore

extension ChoiceTree {
    func hasSameRepresentation(as other: ChoiceTree) -> Bool {
        switch (self, other) {
            case let (.choice(choice, metadata), .choice(otherChoice, otherMetadata)):
                choice == otherChoice && metadata == otherMetadata
            case (.just, .just):
                true
            case let (
            .sequence(elements, metadata),
            .sequence(otherElements, otherMetadata)
        ):
                metadata == otherMetadata
                    && elements.haveSameRepresentations(as: otherElements)
            case let (.branch(branch), .branch(otherBranch)):
                branch.fingerprint == otherBranch.fingerprint
                    && branch.weight == otherBranch.weight
                    && branch.id == otherBranch.id
                    && branch.branchCount == otherBranch.branchCount
                    && branch.isSelected == otherBranch.isSelected
                    && branch.choice.hasSameRepresentation(as: otherBranch.choice)
            case let (
            .group(children, isOpaque),
            .group(otherChildren, otherIsOpaque)
        ):
                isOpaque == otherIsOpaque
                    && children.haveSameRepresentations(as: otherChildren)
            case let (.getSize(size), .getSize(otherSize)):
                size == otherSize
            case let (
            .resize(size, choices),
            .resize(otherSize, otherChoices)
        ):
                size == otherSize
                    && choices.haveSameRepresentations(as: otherChoices)
            case let (
            .bind(fingerprint, inner, bound),
            .bind(otherFingerprint, otherInner, otherBound)
        ):
                fingerprint == otherFingerprint
                    && inner.hasSameRepresentation(as: otherInner)
                    && bound.hasSameRepresentation(as: otherBound)
            default:
                false
        }
    }
}

extension [ChoiceTree] {
    func haveSameRepresentations(as other: [ChoiceTree]) -> Bool {
        count == other.count
            && zip(self, other).allSatisfy { element, otherElement in
                element.hasSameRepresentation(as: otherElement)
            }
    }
}
