@testable import ExhaustCore

/// Lets parity suites build one ``EncoderInput`` for both reducers.
extension ScopedEncoderInput {
    init(_ input: EncoderInput) {
        self.init(
            baseSequence: input.baseSequence,
            tree: input.tree,
            graph: input.graph,
            warmStartRecords: input.warmStartRecords
        )
    }
}

extension ScopedEncoder {
    func reducer(_ scope: Scope, input: EncoderInput) -> ScopedReducer {
        reducer(scope, input: ScopedEncoderInput(input))
    }
}
