/// Replaces distinct positions without changing sequence length, independently of graph nodes or the search that chose the edits.
///
/// The first edit is inline so a single-position candidate needs no edit-array allocation. Additional edits retain insertion order; positions must be unique and valid in the baseline supplied to hashing and restoration.
struct SequencePatch: RandomAccessCollection, Equatable {
    /// Carries the complete entry so value ranges and structural markers survive deferred materialization.
    struct Edit: Equatable {
        let position: Int
        let replacement: ChoiceSequenceValue
    }

    private var firstEdit: Edit?
    private var additional: [Edit] = []

    init(minimumCapacity: Int = 0) {
        additional.reserveCapacity(Swift.max(0, minimumCapacity - 1))
    }

    init(_ edit: Edit) {
        firstEdit = edit
    }

    var startIndex: Int {
        0
    }

    var endIndex: Int {
        firstEdit == nil ? 0 : additional.count + 1
    }

    subscript(index: Int) -> Edit {
        guard index == 0 else {
            return additional[index - 1]
        }
        guard let firstEdit else {
            preconditionFailure("Index zero requires a nonempty sequence patch")
        }
        return firstEdit
    }

    /// Duplicate positions would cancel hash contributions incorrectly, even though the last write would win during materialization.
    mutating func append(_ edit: Edit) {
        assert(contains(where: { $0.position == edit.position }) == false)
        guard firstEdit != nil else {
            firstEdit = edit
            return
        }
        additional.append(edit)
    }

    /// Updates only edited contributions; the hash and sequence must describe the same baseline.
    func hash(baseHash: UInt64, baseSequence: ChoiceSequence) -> UInt64 {
        baseSequence.withUnsafeBufferPointer { buffer in
            var hash = baseHash
            for edit in self {
                hash ^= ZobristHash.contribution(at: edit.position, buffer[edit.position])
                hash ^= ZobristHash.contribution(at: edit.position, edit.replacement)
            }
            return hash
        }
    }

    /// Requires a buffer restored to this patch's baseline; untouched entries are not rewritten.
    func write(into candidate: inout ChoiceSequence) {
        candidate.withUnsafeMutableBufferPointer { buffer in
            for edit in self {
                buffer[edit.position] = edit.replacement
            }
        }
    }

    /// Undoes this patch before reusing the buffer for another candidate against the same baseline.
    func restore(into candidate: inout ChoiceSequence, baseSequence: ChoiceSequence) {
        candidate.withUnsafeMutableBufferPointer { buffer in
            for edit in self {
                buffer[edit.position] = baseSequence[edit.position]
            }
        }
    }
}
