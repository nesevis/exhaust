package extension ChoiceTree {
    /// Extracts per-element ``ChoiceSequence`` segments from the first `.sequence` node in the tree.
    ///
    /// The tree from `Gen.arrayOf(taggedCommandGen)` wraps a `.sequence` node inside length-generator binds and groups. This method walks through that wrapping to find the sequence, then flattens each element subtree independently. Each returned segment is the ChoiceSequence recipe that produced one command — a stable identity for cache fingerprinting regardless of how the command is later pruned or reordered.
    ///
    /// Returns `nil` if no `.sequence` node is found.
    func perElementSegments() -> [ChoiceSequence]? {
        guard let elements = Self.findSequenceElements(in: self) else { return nil }
        return elements.map { ChoiceSequence.flatten($0) }
    }

    static func findSequenceElements(in tree: ChoiceTree) -> [ChoiceTree]? {
        switch tree {
            case let .sequence(elements, _):
                return elements
            case let .bind(_, inner, bound):
                return findSequenceElements(in: inner) ?? findSequenceElements(in: bound)
            case let .group(children, _):
                for child in children {
                    if let found = findSequenceElements(in: child) { return found }
                }
                return nil
            case let .resize(_, choices):
                for child in choices {
                    if let found = findSequenceElements(in: child) { return found }
                }
                return nil
            case .choice, .just, .branch, .getSize:
                return nil
        }
    }
}
