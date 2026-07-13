// Canonical identity for a reduced counterexample, used to key the fault inventory.

package extension Collection<ChoiceSequenceValue> {
    /// A canonical identity string for a flattened choice sequence, stable across reduction paths that reach the same value.
    ///
    /// Keeps container structure, branch selections, and value bit patterns; drops the path-dependent bookkeeping that raw ``ChoiceSequence`` equality counts (`.sequence` valid ranges and length-explicit flags, `.branch` fingerprints, and the value `tag`). Compute it over a sequence flattened with `skipBindInners: true` (see ``ChoiceSequence/flatten(_:includingAllBranches:skipBindInners:)``), which additionally omits the redundant bind-inner subtree — the largest source of over-splitting for length-coupled and recursive generators.
    ///
    /// Dropping this bookkeeping cannot false-merge distinct values. The metadata is generation context, not value content. The `tag` is dropped because the reducer re-derives it inconsistently across paths (the same field's value appears tagged `uint8` on one reduction and `uint16` on another) while the decoded value is identical; a value's position in the structure fixes its field and therefore its type, so the bit pattern alone identifies it. A bind-inner that ever affected the value did so by driving synthesis of content that then appears in the bound. Cheap: one linear pass, no reflection, no `Hashable` requirement on the property's output.
    var clusterKey: String {
        var key = ""
        key.reserveCapacity(underestimatedCount * 6)
        for entry in self {
            switch entry {
                case .group(true):
                    key += "("
                case .group(false):
                    key += ")"
                case .sequence(true, _, _):
                    key += "["
                case .sequence(false, _, _):
                    key += "]"
                case .bind(true):
                    key += "{"
                case .bind(false):
                    key += "}"
                case .just:
                    key += "J"
                case let .branch(branch):
                    key += "B\(branch.id)/\(branch.branchCount);"
                case let .value(value):
                    key += "V\(value.choice.bitPattern64);"
            }
        }
        return key
    }
}
