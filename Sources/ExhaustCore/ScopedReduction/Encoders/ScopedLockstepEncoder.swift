//
//  ScopedLockstepEncoder.swift
//  Exhaust
//

// MARK: - Lockstep Encoder

/// Moves groups of same-typed sibling values by the same delta at once, so properties that relate siblings keep holding while they decrease together.
///
/// Value edits apply to the graph in place, so the search keeps going after an acceptance, working from the accepted candidate.
enum ScopedLockstepEncoder: ScopedEncoder {
    static let name: EncoderName = .lockstep
    static let isValueDependent = true
    static let requiresGenerator = false
    static let isPathChanging = false
    static let admissionOrder: ReductionOrder = .notLarger
    static let rebuildsAfterAcceptance = false

    static func reducer(_ scope: TandemScope, input: ScopedEncoderInput) -> ScopedReducer {
        .search(
            ScopedLockstepSearch(
                scope: scope,
                sequence: input.baseSequence,
                graph: input.graph,
                maxSuffixWindows: input.tuning.lockstepMaxSuffixWindows
            ),
            configuration: .standard
        )
    }
}

// MARK: - Dispatch Requirements

extension ScopedLockstepEncoder {
    static func gate(_ _: TandemScope) -> ScopedDispatchGate {
        .open
    }

    static func convergenceInvalidatedByAcceptance(_: TandemScope, in _: ChoiceGraph) -> ClosedRange<Int>? {
        nil
    }

    static func isValid(_: TandemScope, in _: ChoiceGraph) -> Bool {
        true
    }

    /// A search, whose outcome the scope does not determine.
    static func rejectionKey(_: TandemScope) -> ScopedRejectionKey? {
        nil
    }
}
