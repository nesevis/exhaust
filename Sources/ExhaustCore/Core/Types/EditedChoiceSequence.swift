/// Keeps a value-only edit attached to its shared base so replay cannot silently drop the edit. Structural reads may use the base because entry kinds never change.
package struct EditedChoiceSequence {
    package let base: ChoiceSequence
    private let replacement: ChoiceSequenceValueReplacement?

    package init(_ base: consuming ChoiceSequence) {
        self.base = base
        replacement = nil
    }

    init(_ base: consuming ChoiceSequence, replacement: ChoiceSequenceValueReplacement) {
        precondition(base.indices.contains(replacement.index) && base[replacement.index].value != nil)
        self.base = base
        self.replacement = replacement
    }

    package var count: Int {
        base.count
    }

    @inline(__always)
    package func value(at index: Int) -> ChoiceSequenceValue.Value? {
        guard base.indices.contains(index) else {
            return nil
        }
        if let replacement, replacement.index == index {
            return replacement.value
        }
        return base[index].value
    }

    /// Copies only when a consumer requires an owned sequence containing the edit.
    package func materialized() -> ChoiceSequence {
        guard let replacement else {
            return base
        }
        var result = base
        result[replacement.index] = .value(replacement.value)
        return result
    }
}

/// A value-only edit over a shared sequence. Structural positions remain valid because the replacement cannot change an entry's kind.
struct ChoiceSequenceValueReplacement {
    let index: Int
    let value: ChoiceSequenceValue.Value
}
