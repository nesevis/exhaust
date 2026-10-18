//
//  ReductionDecoder.swift
//  Exhaust
//

// MARK: - Counterexample

/// The incumbent: a sequence, its tree, and the output the property was run on, kept together so they cannot drift apart.
///
/// The runner holds the incumbent and lends it to each interpreter. Relax round rollback restores a copy; no property call is needed to recover the output.
///
/// The output is type-erased so encoders and the interpreter cannot inspect it. Only the runner's final cast reads it.
struct Counterexample {
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
    func admits(_ decoded: Counterexample, under order: ReductionOrder) -> Bool {
        switch order {
            case .notLarger:
                sequence.shortLexPrecedes(decoded.sequence) == false
            case .unordered:
                true
        }
    }
}

/// The ordering an admitted candidate must satisfy against the incumbent.
enum ReductionOrder {
    /// Ordinary probes. Equal sequences are lateral moves and stay admissible.
    case notLarger
    /// The numeric reorder pass, whose reorderings need not precede the incumbent.
    case unordered
}

// MARK: - Decoding Requirement

/// The inputs to decoder selection that arrive with each candidate: the encoder's declared requirement and ordering, the candidate's mutation, and its admission.
struct DecodingRequirement {
    let requiresExactDecoder: Bool
    let mutation: ProjectedMutation
    let admission: DecoderAdmission
    /// The ordering the encoder admits decodings under. Guided decoding enforces shortlex improvement itself, so an unordered encoder must switch that check off for its order to take effect.
    let admissionOrder: ReductionOrder
}

/// The decoder's answer for one candidate.
struct ReductionDecoding {
    let outcome: SequenceDecodingOutcome
    let selection: ReductionDecoder.Selection

    /// The complete counterexample for an admitted property failure, or nil.
    var recovered: Counterexample? {
        outcome.reduction.map(Counterexample.init)
    }
}

// MARK: - Decoder

/// Decodes candidates and lifts prefixes. Holds the generator and the property; retains no outputs.
///
/// Decoder selection lives here: the encoder's requirement and the candidate's mutation and admission arrive with the candidate, and `hasBind` is set by the runner from the graph.
struct ReductionDecoder {
    let generator: AnyGenerator
    let property: (Any) -> Bool
    let probeWrapper: ProbeWrapper?
    var hasBind: Bool

    /// The decoding mode `requirement` selects for the current sequence.
    func selection(for requirement: DecodingRequirement) -> Selection {
        Self.selectDecoder(
            for: requirement.mutation,
            requiresExactDecoder: requirement.requiresExactDecoder,
            hasBind: hasBind,
            admission: requirement.admission,
            admissionOrder: requirement.admissionOrder
        )
    }

    /// Decodes `candidate` under `selection`, running the property, against `incumbent`, which supplies the fallback tree and the guided admission baseline.
    func decode(
        _ candidate: ChoiceSequence,
        against incumbent: Counterexample,
        selection: Selection,
        precomputedHash: UInt64
    ) -> ReductionDecoding {
        let outcome = decode(
            candidate,
            using: selection.decoder(fallbackTree: incumbent.tree),
            against: incumbent,
            precomputedHash: precomputedHash
        )
        return ReductionDecoding(outcome: outcome, selection: selection)
    }

    /// Decodes `candidate` with `decoder`, running the property, against `incumbent`. For callers that fix their decoder rather than selecting one per candidate.
    func decode(
        _ candidate: ChoiceSequence,
        using decoder: SequenceDecoder,
        against incumbent: Counterexample,
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
    /// `materializePicks` is true when the probe may change the active branch path, so the decoder must reconstruct every branch alternative. `skipsShortlexCheck` is true for an unordered encoder, whose admission the interpreter decides after decoding.
    enum Selection {
        case exact(materializePicks: Bool, admission: DecoderAdmission)
        case guided(materializePicks: Bool, skipsShortlexCheck: Bool)

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
                case let .exact(materializePicks, _), let .guided(materializePicks, _):
                    materializePicks
            }
        }

        func decoder(fallbackTree: ChoiceTree) -> SequenceDecoder {
            switch self {
                case let .exact(materializePicks, admission):
                    .exact(materializePicks: materializePicks, admission: admission)
                case let .guided(materializePicks, skipsShortlexCheck):
                    .guided(fallbackTree: fallbackTree, materializePicks: materializePicks, skipShortlexCheck: skipsShortlexCheck)
            }
        }
    }

    /// Chooses guided decoding when the candidate can reshape bound content, unless the search requires exact decoding or the admission inspects decoded history. Every other candidate decodes exactly.
    ///
    /// A reshaping candidate needs the incumbent's tree as a fallback for the bound content it regenerates, which only guided decoding has. An admission that inspects decoded history overrides that, because only the exact decoder produces the history it reads. A leaf-value candidate can reshape only through a change marked `mayReshape`; any other mutation can reshape whenever the sequence holds a bind.
    private static func selectDecoder(
        for mutation: ProjectedMutation,
        requiresExactDecoder: Bool,
        hasBind: Bool,
        admission: DecoderAdmission,
        admissionOrder: ReductionOrder
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
            let skipsShortlexCheck = switch admissionOrder {
                case .notLarger:
                    false
                case .unordered:
                    true
            }
            return .guided(materializePicks: picksUnchanged == false, skipsShortlexCheck: skipsShortlexCheck)
        }
        return .exact(materializePicks: picksUnchanged == false, admission: admission)
    }
}
