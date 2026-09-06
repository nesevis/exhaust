// Property invocation for the fuzz loop: the attribution bracket, the crash breadcrumb, duplicate skipping, and the search-attempt evaluation every phase shares.

extension FuzzRunner {
    // MARK: - Probes

    /// The one attribution bracket: opens the source, notes the value, runs `evaluate`, reads the hits, and closes the source. Every attributed evaluation (search attempts, post-reduction classification, recovery re-attribution) goes through here, so the bracket is spelled out once and a later edit cannot leave one copy without its `endAttempt()`.
    ///
    /// The bracket encloses `evaluate` and nothing else. Candidate production (generation, materialization, reflection) runs before it and reduction probes run outside it, so Exhaust's own instrumented code and the generator's transform closures never enter a signature. Every phase excludes its generation the same way, so a screening signature and a mutation signature over the same property path stay comparable. Code the system under test runs during generation (an initializer with validation called from a generator closure) is excluded with it.
    func attribute(
        _ value: Output,
        evaluate: (Output) -> FuzzVerdict
    ) -> (verdict: FuzzVerdict, hits: [(edge: Int, hitCount: UInt8)]) {
        source.beginAttempt()
        if source.wantsValues {
            source.noteValue(value)
        }
        let verdict = evaluate(value)
        // Reused across attempts: a fresh array grows through roughly eleven reallocations on the way to the few thousand edges a typical attempt lights. Admitted candidates retain the returned array in CorpusEntry.hits (for restore re-offer), so the removeAll after each admission triggers one CoW reallocation; every non-admitting attempt reuses the capacity.
        hitsBuffer.removeAll(keepingCapacity: true)
        source.appendHitEdges(to: &hitsBuffer)
        source.endAttempt()
        return (verdict, hitsBuffer)
    }

    /// Marks the breadcrumb slot occupied for exactly the span of `evaluate`.
    ///
    /// Every user-property invocation the run makes goes through here — search attempts, reduction and normalization probes, post-reduction classification, and recovery re-judgement — so an abnormal termination names the probe that caused it. Only search attempts recorded a slot before, which meant a trap in reduction was attributed to whichever search candidate ran last, and the next run then reported that candidate as the trap and quarantined it and its parent.
    ///
    /// The clear is a `defer` rather than a line after the call, and the span is the property invocation rather than the whole attribution bracket, because an occupied slot means "an abnormal termination here is this input's fault". A slot still occupied through the comparison harvest and the coverage teardown names a probe that already returned.
    func withBreadcrumb<Result>(
        candidateHash: UInt64,
        parentHash: UInt64 = 0,
        kind: FuzzProbeKind,
        sequence: ChoiceSequence? = nil,
        _ evaluate: () -> Result
    ) -> Result {
        guard let breadcrumb else {
            return evaluate()
        }
        return breadcrumb.marking(
            candidateHash: candidateHash,
            parentHash: parentHash,
            kind: kind,
            sequence: sequence,
            evaluate
        )
    }

    /// Invokes the property on one probe with the breadcrumb slot marked, and stops the run if the verdict reports escaped work.
    ///
    /// Every direct property invocation the runner makes goes through here, so the escape has one consumer: the verdict is the property's channel for it, and this is where the runner reads that channel. Reduction probes are the exception, because the reducer speaks Bool; their escape comes back on ``FuzzReductionResult/escaped``.
    func judge(
        _ value: Output,
        candidateHash: UInt64,
        parentHash: UInt64 = 0,
        kind: FuzzProbeKind,
        sequence: ChoiceSequence?
    ) -> FuzzVerdict {
        let verdict = withBreadcrumb(candidateHash: candidateHash, parentHash: parentHash, kind: kind, sequence: sequence) {
            property(value)
        }
        if verdict.isEscaped {
            forcedTermination = .uncontainedAsyncWork
        }
        return verdict
    }

    /// The bracket the reducer runs each probe's property invocation inside, marking the probe's own candidate.
    ///
    /// Built per reduction rather than stored, because the bracket is `@Sendable` and cannot capture the runner: taking the breadcrumb as a value here is what lets it reach one, and by reduction time ``setUpPersistence()`` has created it.
    static func reductionProbeWrapper(_ breadcrumb: FuzzBreadcrumb?) -> ProbeWrapper {
        guard let breadcrumb else {
            return { _, evaluate in evaluate() }
        }
        return { candidate, evaluate in
            breadcrumb.marking(
                candidateHash: ZobristHash.hash(of: candidate),
                kind: .reduction,
                sequence: candidate,
                evaluate
            )
        }
    }

    /// Whether the run recently evaluated this sequence, recording it either way.
    ///
    /// A skipped candidate counts toward the phase's attempts, never toward `evaluatedSearchCases` or the corpus. The check assumes the property is a function of the sequence, as replay already does.
    func isRecentDuplicate(hash: UInt64) -> Bool {
        corpus.markEvaluated(hash: hash)
    }

    /// One search attempt's evaluation: runs the property inside the attribution bracket with the breadcrumb slot, comparison capture, and property timing around it, and notes whether the run has seen an edge yet.
    func evaluateInBracket(
        _ value: Output,
        recordingBreadcrumb slot: (candidateHash: UInt64, parentHash: UInt64, sequence: ChoiceSequence)?
    ) -> (verdict: FuzzVerdict, hits: [(edge: Int, hitCount: UInt8)]) {
        let capturesComparisons = source.wantsComparisons
        let (verdict, hits) = attribute(value) { value in
            if capturesComparisons {
                source.beginComparisonCapture()
            }
            let propertyStart = monotonicNanoseconds()
            let verdict = judge(
                value,
                candidateHash: slot?.candidateHash ?? 0,
                parentHash: slot?.parentHash ?? 0,
                kind: .search,
                sequence: slot?.sequence
            )
            timing.propertyNanoseconds += monotonicNanoseconds() - propertyStart
            if capturesComparisons {
                source.endComparisonCapture()
                // One call for the whole harvest: the per-record closure form cost a dictionary lookup and a dynamic exclusivity check on the pool per operand, 7% of a run on a comparison-heavy target.
                source.drainComparisonRecords(into: &comparisonPool)
            }
            return verdict
        }
        if hits.isEmpty == false {
            sawAnyEdge = true
        }
        return (verdict, hits)
    }

    /// Evaluates the reduced value once in a bracket of its own and returns its coverage signature.
    func attributedSignature(of value: Output, sequence: ChoiceSequence) -> BitSet {
        let (_, hits) = attribute(value) { value in
            counts.invocations.record(.classification, invocations: 1)
            return judge(
                value,
                candidateHash: ZobristHash.hash(of: sequence),
                kind: .classification,
                sequence: sequence
            )
        }
        var signature = BitSet(capacity: source.edgeCount)
        for (edge, _) in hits {
            signature.insert(edge)
        }
        return signature
    }
}
