//
//  ScopedDecoder.swift
//  Exhaust
//

// MARK: - Counterexample

/// The incumbent: a sequence, its tree, and the output the property was run on, kept together so they cannot drift apart.
///
/// The runner holds the incumbent and lends it to each interpreter. Relax round rollback restores a copy; no property call is needed to recover the output.
///
/// The output is type-erased so encoders and the interpreter cannot inspect it. Only the runner's final cast reads it.
struct ScopedCounterexample {
    let sequence: ChoiceSequence
    let tree: ChoiceTree
    let output: Any

    init(sequence: ChoiceSequence, tree: ChoiceTree, output: Any) {
        self.sequence = sequence
        self.tree = tree
        self.output = output
    }

    /// The counterexample a decoded property failure describes.
    init(_ reduction: ReductionResult<Any>) {
        self.init(sequence: reduction.sequence, tree: reduction.tree, output: reduction.output)
    }

    /// Whether `decoded` may replace this incumbent under `order`.
    func admits(_ decoded: ScopedCounterexample, under order: ReductionOrder) -> Bool {
        switch order {
            case .notLarger:
                sequence.shortLexPrecedes(decoded.sequence) == false
            case .unordered:
                true
            case .strictlySmaller:
                decoded.sequence.shortLexPrecedes(sequence)
        }
    }
}

/// The ordering an admitted candidate must satisfy against the incumbent.
enum ReductionOrder {
    /// Ordinary probes. Equal sequences are lateral moves and stay admissible.
    case notLarger
    /// `numericReorder` and relax round perturbation.
    case unordered
    /// Improving pivots and relax round settlement.
    case strictlySmaller
}

// MARK: - Decoding Requirement

/// The inputs to decoder selection that arrive with each candidate: the encoder's declared requirement, the candidate's mutation, and its admission.
struct ScopedDecodingRequirement {
    let requiresExactDecoder: Bool
    let mutation: ProjectedMutation
    let admission: DecoderAdmission
}

/// The decoder's answer for one candidate.
struct ScopedDecoding {
    let outcome: SequenceDecodingOutcome
    let selection: ScopedDecoder.Selection

    /// The complete counterexample for an admitted property failure, or nil.
    var recovered: ScopedCounterexample? {
        outcome.reduction.map(ScopedCounterexample.init)
    }
}

// MARK: - Decoder

/// Decodes candidates and lifts prefixes. Holds the generator and the property; retains no outputs.
///
/// Decoder selection lives here: the encoder's requirement and the candidate's mutation and admission arrive with the candidate, and `hasBind` is set by the runner from the graph.
struct ScopedDecoder {
    let generator: AnyGenerator
    let property: (Any) -> Bool
    let probeWrapper: ProbeWrapper?
    var hasBind: Bool

    /// Selects a decoder for `candidate` and decodes it, running the property, against `incumbent`, which supplies the fallback tree and the guided admission baseline.
    func decode(
        _ candidate: ChoiceSequence,
        against incumbent: ScopedCounterexample,
        requirement: ScopedDecodingRequirement,
        precomputedHash: UInt64
    ) -> ScopedDecoding {
        let selection = Self.selectDecoder(
            for: requirement.mutation,
            requiresExactDecoder: requirement.requiresExactDecoder,
            hasBind: hasBind,
            admission: requirement.admission
        )
        let outcome = decode(
            candidate,
            using: selection.decoder(fallbackTree: incumbent.tree),
            against: incumbent,
            precomputedHash: precomputedHash
        )
        return ScopedDecoding(outcome: outcome, selection: selection)
    }

    /// Decodes `candidate` with `decoder`, running the property, against `incumbent`. For callers that fix their decoder rather than selecting one per candidate.
    func decode(
        _ candidate: ChoiceSequence,
        using decoder: SequenceDecoder,
        against incumbent: ScopedCounterexample,
        precomputedHash: UInt64? = nil
    ) -> SequenceDecodingOutcome {
        // Admission does not read filter observations, so they are collected and discarded.
        var filterObservations: [UInt64: FilterObservation] = [:]
        return decoder.decodeAny(
            candidate: candidate,
            gen: generator,
            tree: incumbent.tree,
            originalSequence: incumbent.sequence,
            property: wrappedProperty(for: candidate),
            filterObservations: &filterObservations,
            precomputedHash: precomputedHash
        )
    }

    /// Materializes `prefix` in guided mode without running the property, so a composition can inspect the lifted structure before emitting any candidate.
    func lift(_ prefix: ChoiceSequence, fallbackTree: ChoiceTree, maximumSequenceCount: Int?) -> LiftResult? {
        Materializer.guidedLift(
            generator: generator,
            prefix: prefix,
            fallbackTree: fallbackTree,
            maximumSequenceCount: maximumSequenceCount
        )
        .map { tree in LiftResult(tree: tree, sequence: ChoiceSequence(tree)) }
    }

    /// The property with the host's wrapper around it, carrying the candidate the probe is testing.
    private func wrappedProperty(for candidate: ChoiceSequence) -> (Any) -> Bool {
        guard let probeWrapper else {
            return property
        }
        let hostProperty = property
        return { output in
            probeWrapper(candidate) { hostProperty(output) }
        }
    }

    // MARK: - Selection

    /// The decoding mode chosen for one candidate.
    ///
    /// Pure function of the mutation type, the encoder's decoder requirement and admission, and whether the sequence contains binds. A non-standard admission forces exact decoding, because only the exact decoder can apply it. `materializePicks` is true when the probe changes the active branch path and the decoder must reconstruct all branch alternatives.
    enum Selection {
        case exact(materializePicks: Bool, admission: DecoderAdmission)
        case guided(materializePicks: Bool)

        var preferExact: Bool {
            switch self {
                case .exact:
                    true
                case .guided:
                    false
            }
        }

        var materializePicks: Bool {
            switch self {
                case let .exact(materializePicks, _), let .guided(materializePicks):
                    materializePicks
            }
        }

        func decoder(fallbackTree: ChoiceTree) -> SequenceDecoder {
            switch self {
                case let .exact(materializePicks, admission):
                    .exact(materializePicks: materializePicks, admission: admission)
                case let .guided(materializePicks):
                    .guided(fallbackTree: fallbackTree, materializePicks: materializePicks)
            }
        }
    }

    /// Chooses exact decoding when the search requires it, when the admission inspects decoded history, or when the candidate can reshape bound content, and guided decoding otherwise. A non-standard admission forces exact decoding because only the exact decoder can apply it. `materializePicks` is true when the candidate changes the active branch path.
    private static func selectDecoder(
        for mutation: ProjectedMutation,
        requiresExactDecoder: Bool,
        hasBind: Bool,
        admission: DecoderAdmission = .standard
    ) -> Selection {
        let picksUnchanged = switch mutation {
            case let .leafValues(changes):
                changes.contains(where: \.mayReshape) == false
            case .sequenceElementsRemoved, .sequenceElementsMigrated, .siblingsSwapped, .sequenceReordered:
                true
            case .branchSelected, .selfSimilarReplaced, .descendantPromoted:
                false
        }
        let probeCanReshape = switch mutation {
            case let .leafValues(changes):
                changes.contains(where: \.mayReshape)
            default:
                hasBind
        }
        guard requiresExactDecoder || admission.inspectsDecodedHistory || probeCanReshape == false else {
            return .guided(materializePicks: picksUnchanged == false)
        }
        return .exact(materializePicks: picksUnchanged == false, admission: admission)
    }
}
