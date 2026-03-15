import ExhaustCore
import Testing

@Suite("SequenceDecoder.for")
struct SequenceDecoderForTests {
    // MARK: - Helpers

    /// A non-empty bind index for testing contexts that have binds present.
    private static func makeBoundBindIndex() -> BindSpanIndex {
        // Build a bind tree and flatten it to get a valid bind sequence.
        let inner = ChoiceTree.choice(.unsigned(1, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true))
        let bound = ChoiceTree.choice(.unsigned(2, .uint64), .init(validRange: 0 ... 10, isRangeExplicit: true))
        let tree = ChoiceTree.bind(inner: inner, bound: bound)
        let seq = ChoiceSequence.flatten(tree)
        return BindSpanIndex(from: seq)
    }

    // MARK: - .relaxed strictness

    @Test("Relaxed strictness at depth 0 without binds produces guided decoder")
    func relaxedStrictnessDepth0NoBind() {
        // Deletion (.relaxed) invalidates the tree's positional mapping even
        // without binds. GuidedMaterializer rebuilds a consistent (sequence, tree)
        // pair and applies the shortlex guard.
        let context = DecoderContext(
            depth: .specific(0), bindIndex: nil,
            fallbackTree: nil, strictness: .relaxed
        )
        let decoder = SequenceDecoder.for(context)
        guard case .guided = decoder else {
            Issue.record("Expected .guided, got \(decoder)")
            return
        }
    }

    @Test("Relaxed strictness at depth > 0 produces guided decoder")
    func relaxedStrictnessDeepDepth() {
        let context = DecoderContext(
            depth: .specific(2), bindIndex: nil,
            fallbackTree: nil, strictness: .relaxed
        )
        let decoder = SequenceDecoder.for(context)
        guard case .guided = decoder else {
            Issue.record("Expected .guided, got \(decoder)")
            return
        }
    }

    // MARK: - .specific(n) where n > 0, no binds, .normal → .direct

    @Test("Normal strictness at depth > 0 without binds produces direct decoder")
    func normalDeepNoBind() {
        let context = DecoderContext(
            depth: .specific(3), bindIndex: nil,
            fallbackTree: nil, strictness: .normal
        )
        let decoder = SequenceDecoder.for(context)
        guard case .direct = decoder else {
            Issue.record("Expected .direct, got \(decoder)")
            return
        }
    }

    // MARK: - .specific(0), binds present, .normal → .guided

    @Test("Normal strictness at depth 0 with binds produces guided decoder")
    func normalDepth0WithBinds() {
        let bindIndex = Self.makeBoundBindIndex()
        let context = DecoderContext(
            depth: .specific(0), bindIndex: bindIndex,
            fallbackTree: nil, strictness: .normal
        )
        let decoder = SequenceDecoder.for(context)
        guard case .guided = decoder else {
            Issue.record("Expected .guided, got \(decoder)")
            return
        }
    }

    // MARK: - .specific(0), no binds, .normal → .direct

    @Test("Normal strictness at depth 0 without binds produces direct decoder")
    func normalDepth0NoBind() {
        let context = DecoderContext(
            depth: .specific(0), bindIndex: nil,
            fallbackTree: nil, strictness: .normal
        )
        let decoder = SequenceDecoder.for(context)
        guard case .direct = decoder else {
            Issue.record("Expected .direct, got \(decoder)")
            return
        }
    }

    // MARK: - .global, binds present → .crossStage

    @Test("Global depth with binds produces crossStage decoder")
    func globalWithBinds() {
        let bindIndex = Self.makeBoundBindIndex()
        let context = DecoderContext(
            depth: .global, bindIndex: bindIndex,
            fallbackTree: nil, strictness: .normal
        )
        let decoder = SequenceDecoder.for(context)
        guard case .crossStage = decoder else {
            Issue.record("Expected .crossStage, got \(decoder)")
            return
        }
    }

    // MARK: - .global, no binds → .direct

    @Test("Global depth without binds produces direct decoder")
    func globalNoBind() {
        let context = DecoderContext(
            depth: .global, bindIndex: nil,
            fallbackTree: nil, strictness: .normal
        )
        let decoder = SequenceDecoder.for(context)
        guard case .direct = decoder else {
            Issue.record("Expected .direct, got \(decoder)")
            return
        }
    }

    // MARK: - Empty bind index treated as no binds

    @Test("Empty bind index at depth 0 produces direct decoder")
    func emptyBindIndexDepth0() {
        let emptyBindIndex = BindSpanIndex(from: ChoiceSequence())
        #expect(emptyBindIndex.isEmpty)
        let context = DecoderContext(
            depth: .specific(0), bindIndex: emptyBindIndex,
            fallbackTree: nil, strictness: .normal
        )
        let decoder = SequenceDecoder.for(context)
        guard case .direct = decoder else {
            Issue.record("Expected .direct for empty bind index, got \(decoder)")
            return
        }
    }

    @Test("Empty bind index at global depth produces direct decoder")
    func emptyBindIndexGlobal() {
        let emptyBindIndex = BindSpanIndex(from: ChoiceSequence())
        let context = DecoderContext(
            depth: .global, bindIndex: emptyBindIndex,
            fallbackTree: nil, strictness: .normal
        )
        let decoder = SequenceDecoder.for(context)
        guard case .direct = decoder else {
            Issue.record("Expected .direct for empty bind index at global depth, got \(decoder)")
            return
        }
    }
}
