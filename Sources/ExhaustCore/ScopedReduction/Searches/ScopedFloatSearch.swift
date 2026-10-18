//
//  ScopedFloatSearch.swift
//  Exhaust
//

// MARK: - Float Search

/// Drives float leaves toward their semantic simplest values without changing graph structure, through four stages: special values, truncation, integral binary search, and ratio binary search.
///
/// All leaves have position ranges in the current sequence. Candidates are constructed by modifying leaf values at pre-resolved positions, and an acceptance advances the baseline to the accepted candidate.
///
/// The stages live in `ScopedFloatSearch+Probing.swift`.
struct ScopedFloatSearch: ScopedSearch {
    // MARK: - State

    var state: State

    // MARK: - Float State

    /// One float leaf under search. The mutable fields follow accepted probes, so later stages start from the reduced value.
    struct Target: ScopedLeafMutationSource {
        let nodeID: Int
        let sequenceIndex: Int
        let typeTag: TypeTag
        let validRange: ClosedRange<UInt64>?
        let isRangeExplicit: Bool
        var currentValue: Double
        var currentBitPattern: UInt64
        let mayReshape: Bool
    }

    /// The four stages of float reduction, cheapest first: special values (the reduction target, then the type's greatest finite magnitude, infinity, and NaN), mantissa truncation, integral binary search, and ratio binary search. Constant-count probes run before the iterative searches.
    enum Stage: Int, Comparable {
        case specialValues = 0
        case truncation = 1
        case integralBinarySearch = 2
        case ratioBinarySearch = 3

        static func < (lhs: Stage, rhs: Stage) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// Everything the search carries between pulls: its position across every target and stage, and the convergence records it has gathered. The stages are static functions over this state, so a pull edits it in place. The binary search context is shared between the integral and ratio stages.
    struct State {
        var sequence: ChoiceSequence
        var targets: [Target]
        var currentTargetIndex: Int
        var stage: Stage
        var batchCandidates: [UInt64]
        /// The next batch candidate in the special-values and truncation stages. In the binary search stages, zero until the stepper has started.
        var batchIndex: Int
        var stepper: FindIntegerStepper
        var needsFirstProbe: Bool
        // Stage 2/3 binary search context.
        var binarySearchMinDelta: UInt64
        var binarySearchMaxQuantum: UInt64
        var binarySearchMovesUp: Bool
        var binarySearchCurrentInt: Int64
        // Stage 3 ratio context.
        var ratioDenominator: Int64
        var ratioRemainder: Int64
        var ratioIntegerPart: Int64
        var ratioDistance: UInt64
        /// Convergence records keyed by graph node ID, which ``ScopedFloatSearch/finish(pending:)`` reports.
        var convergenceStore: [Int: ConvergedOrigin] = [:]
    }

    // MARK: - Search

    /// Starts on `scope` over `sequence`.
    init(scope: FloatMinimizationScope, sequence: ChoiceSequence, graph: ChoiceGraph) {
        state = Self.initialState(scope: scope, sequence: sequence, graph: graph)
    }

    mutating func next(_ feedback: ScopedSearchFeedback, into buffer: inout ChoiceSequence) -> ScopedCandidate? {
        if case let .accepted(recovered) = feedback {
            // Leaf positions were resolved against the dispatch-time sequence, so a recovered sequence of a different length ends the search.
            guard recovered.count == state.sequence.count else {
                return nil
            }
            state.sequence = recovered
        }
        guard let built = Self.nextProbe(state: &state, lastAccepted: feedback.isAccepted) else {
            return nil
        }
        buffer = built
        let mutation = state.targets.leafValuesMutation(candidate: buffer, baseline: state.sequence)
        return .written(mutation: mutation, admission: .standard)
    }

    /// Reports the convergence records gathered so far.
    consuming func finish(pending _: ScopedSearchFeedback) -> ScopedSearchReport {
        ScopedSearchReport(convergenceRecords: state.convergenceStore)
    }
}
