// Comparison-operand injection for the fuzz loop: the reconstructor and graft candidate-production paths, and their shared evaluation tail.

extension FuzzRunner {
    /// Draws one harvested operand, reconstructs an output value from its bytes, reflects that value through the generator to the choices that produce it, and evaluates the reflected candidate.
    ///
    /// This is the general trace-cmp path: the reconstructed value flows through the generator's leaves, so `Interpreters.reflect` supplies the choices (and their per-type encoding) rather than the mutator poking one integer site. Returns false when the draw does not reconstruct or does not reflect — a cheap miss, the same discipline as a range-incompatible injection.
    func reflectionInjectionAttempt() -> Bool {
        guard let reflectionReconstructor,
              let word = comparisonPool.drawValue(sitePick: randomUnit(), valuePick: randomUnit())
        else {
            return false
        }
        guard let value = reflectionReconstructor(word),
              let tree = try? Interpreters.reflect(gen, with: value)
        else {
            return false
        }
        let sequence = ChoiceSequence.flatten(tree)
        return evaluateInjected(sequence: sequence, tree: tree, value: value, parent: nil)
    }

    /// Grafts a harvested operand into one field of a materialized corpus parent, reflects the whole composite through the generator, and evaluates it.
    ///
    /// The parent scaffolds every field but the grafted one, so a matched prefix from earlier fields survives while the frontier field takes the harvested operand — reflecting the whole value places it in choice space and preserves the rest, the discipline a field cascade needs to climb one comparison at a time. trace-cmp does not report which field a comparison read, so the field index is sprayed; a non-composite generator, an out-of-range field, or a field whose type is not ``OperandReconstructable`` is a cheap miss. Returns false on any miss.
    func reflectionGraftAttempt() -> Bool {
        let parentStart = monotonicNanoseconds()
        let picked = corpus.pickParent(random: randomUnit())
        timing.parentSelectionNanoseconds += monotonicNanoseconds() - parentStart
        guard let (parentIndex, parent) = picked else {
            return false
        }
        let parentSequence = ChoiceSequence.flatten(parent.tree)
        guard case let .success(anyParent, _, _) = Materializer.materializeAny(
            erasedGen,
            prefix: parentSequence,
            mode: .exact
        ),
            let parentValue = anyParent as? Output
        else {
            return false
        }
        guard let word = comparisonPool.drawValue(sitePick: randomUnit(), valuePick: randomUnit()) else {
            return false
        }
        let fieldIndex = Int(prng.next(upperBound: UInt64(FuzzTunables.reflectionGraftPositionSpan)))
        guard let tree = try? Interpreters.reflectGraftingOperand(
            into: gen,
            parent: parentValue,
            index: fieldIndex,
            operand: word
        ) else {
            return false
        }
        let sequence = ChoiceSequence.flatten(tree)
        guard case let .success(anyValue, _, _) = Materializer.materializeAny(
            erasedGen,
            prefix: sequence,
            mode: .exact
        ),
            let value = anyValue as? Output
        else {
            return false
        }
        // The graft is a child of the parent it scaffolds. The normal mutation path increments the count in its child loop and lets recordAttempt attribute the child to its parent; matching that here keeps the count right (recordAttempt only self-increments when parentIndex is nil) and lets the corpus's per-parent accounting learn the child existed.
        counts.mutationAttempts += 1
        return evaluateInjected(sequence: sequence, tree: tree, value: value, parent: (parentIndex, parent))
    }

    /// Evaluates a candidate produced by comparison-operand injection and records the attempt, sharing the tail of the reconstructor and graft paths.
    ///
    /// `parent` is nil for a whole-value candidate reflected from the operand alone, and the grafted corpus entry with its index for a field graft. It sources the breadcrumb's parent hash, the recorded generation, and the attribution index, so a graft counts against its parent the same way a normal mutation does. The whole-value path has no parent, so recordAttempt self-increments the mutation count for it.
    private func evaluateInjected(
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        value: Output,
        parent: (index: Int, entry: CorpusEntry)?
    ) -> Bool {
        source.beginAttempt()
        let sequenceHash = ZobristHash.hash(of: sequence)
        let (verdict, hits) = evaluateInBracket(
            value,
            recordingBreadcrumb: (candidateHash: sequenceHash, parentHash: parent?.entry.hash ?? 0)
        )
        recordAttempt(
            value: value,
            tree: tree,
            sequence: sequence,
            sequenceHash: sequenceHash,
            verdict: verdict,
            hits: hits,
            convergence: 1.0,
            generation: parent.map { $0.entry.generation + 1 } ?? 0,
            phase: .mutation,
            parentIndex: parent?.index
        )
        return true
    }
}
