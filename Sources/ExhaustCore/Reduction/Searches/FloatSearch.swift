//
//  FloatSearch.swift
//  Exhaust
//

// MARK: - Float Search

/// Drives float leaves toward their semantic simplest values without changing graph structure, through five stages: special values, boundaries, precision walk, integral binary search, and ratio binary search.
///
/// Each candidate is a sparse edit at a pre-resolved leaf position. An acceptance advances the baseline to the recovered sequence.
///
/// The stages live in `FloatSearch+Probing.swift`.
struct FloatSearch: ReductionSearch {
    // MARK: - State

    var state: State

    // MARK: - Float State

    /// One float leaf under search. The mutable fields follow accepted probes, so later stages start from the reduced value.
    struct Target: LeafMutationSource {
        let nodeID: Int
        let sequenceIndex: Int
        let typeTag: TypeTag
        let validRange: ClosedRange<UInt64>?
        let isRangeExplicit: Bool
        var currentValue: Double
        var currentBitPattern: UInt64
        let mayReshape: Bool
    }

    /// The five stages of float reduction: special values (the reduction target, the positive counterpart, then the type's greatest finite magnitude, infinity, and NaN), boundary probes, the precision walk over binary grids, integral binary search, and ratio binary search.
    enum Stage: Int, Comparable {
        case specialValues = 0
        case boundaries = 1
        case precisionWalk = 2
        case integralBinarySearch = 3
        case ratioBinarySearch = 4

        static func < (lhs: Stage, rhs: Stage) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// The precision-walk stage's walk over binary grids, driven by ``State/stepper``.
    ///
    /// Step `n` probes the grid 2^-(`n` − 1), coarsest first, and passes when none of that grid's admissible candidates fails. The stepper therefore converges on the coarsest grid whose rounding still fails, in probes logarithmic in that grid's depth, and each failing candidate is committed as it is found. This assumes that once a grid's rounding fails, every finer grid's does too; when it does not, the walk can settle on a finer grid than the coarsest failing one. Candidates come from the value at the start of the walk, and shortlex admission against the current entry keeps every acceptance an improvement.
    struct PrecisionWalk {
        let origin: Double
        let finestGrid: Int
        let tag: TypeTag
        var candidates: [UInt64] = []
        var candidateIndex = 0
        /// Whether the current grid holds a failing candidate. The stepper reads a passing grid as an accepted step.
        var gridFails = false
        /// The emitted candidate awaiting feedback, or nil when the last probe did not come from this walk.
        var outstandingBitPattern: UInt64?

        /// Prepares the candidates of the grid at `step`. A grid at or finer than the origin's finest grid reproduces the origin, which fails, so it needs no probe.
        mutating func begin(step: Int) {
            candidateIndex = 0
            let grid = step - 1
            guard grid < finestGrid else {
                candidates = []
                gridFails = true
                return
            }
            candidates = FloatReduction.gridCandidates(for: origin, grid: grid, tag: tag)
            gridFails = false
        }
    }

    /// Everything the search carries between pulls: its position across every target and stage, and the convergence records it has gathered. The stages are static functions over this state, so a pull edits it in place. The binary search context is shared between the integral and ratio stages.
    struct State {
        var sequence: ChoiceSequence
        var targets: [Target]
        var currentTargetIndex: Int
        var stage: Stage
        var batchCandidates: [UInt64]
        /// The next batch candidate in the special-values and boundary stages. In the binary search stages, zero until the stepper has started.
        var batchIndex: Int
        /// Drives the precision walk's grid steps.
        var stepper: FindIntegerStepper
        /// Drives the integral and ratio stages over step counts from the current value, biased toward the target as ``IntegerSearch`` is.
        var searchStepper: DirectionalStepper?
        let interpolationBinaryThreshold: UInt64
        let interpolationInitialDivisor: UInt64
        var needsFirstProbe: Bool
        // Stage 3/4 binary search context.
        var binarySearchMinDelta: UInt64
        var binarySearchMaxQuantum: UInt64
        var binarySearchMovesUp: Bool
        var binarySearchCurrentInt: Int64
        // Stage 4 ratio context.
        var ratioDenominator: Int64
        var ratioRemainder: Int64
        var ratioIntegerPart: Int64
        var ratioDistance: UInt64
        /// The precision-walk stage's grid walk, armed when the stage is prepared for a fractional leaf. Nil outside that stage and after the walk converges.
        var precisionWalk: PrecisionWalk?
        /// Convergence records keyed by graph node ID, which ``FloatSearch/finish(pending:)`` reports.
        var convergenceStore: [Int: ConvergedOrigin] = [:]
    }

    // MARK: - Search

    /// Starts on `scope` over `sequence`, reading its interpolation limits from `tuning`.
    init(
        scope: FloatMinimizationScope,
        sequence: ChoiceSequence,
        graph: ChoiceGraph,
        tuning: ReductionTuning
    ) {
        state = Self.initialState(scope: scope, sequence: sequence, graph: graph, tuning: tuning)
    }

    mutating func next(_ feedback: SearchFeedback, into _: inout ChoiceSequence) -> ReductionCandidate? {
        if case let .accepted(recovered) = feedback {
            // Leaf positions were resolved against the dispatch-time sequence, so a recovered sequence of a different length ends the search.
            guard recovered.count == state.sequence.count else {
                return nil
            }
            state.sequence = recovered
        }
        return Self.nextProbe(state: &state, lastAccepted: feedback.isAccepted)
    }

    /// Reports the convergence records gathered so far.
    consuming func finish(pending _: SearchFeedback) -> SearchReport {
        SearchReport(convergenceRecords: state.convergenceStore)
    }
}
