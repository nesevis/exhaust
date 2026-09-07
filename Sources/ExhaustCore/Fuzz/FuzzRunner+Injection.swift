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
        // Reconstruction and reflection run outside the bracket, like every other candidate production path; evaluate opens it around the property call.
        guard let value = reflectionReconstructor(word),
              let tree = try? Interpreters.reflect(gen, with: value)
        else {
            return false
        }
        let sequence = ChoiceSequence.flatten(tree)
        evaluate(injectedCandidate(sequence: sequence, tree: tree, value: value, parent: nil))
        return true
    }

    /// Grafts a harvested operand into one field of a materialized corpus parent, reflects the whole composite through the generator, and evaluates it.
    ///
    /// The parent scaffolds every field but the grafted one, so a matched prefix from earlier fields survives while the frontier field takes the harvested operand — reflecting the whole value places it in choice space and preserves the rest, the discipline a field cascade needs to climb one comparison at a time. trace-cmp does not report which field a comparison read, so the field index is sprayed; a non-composite generator, an out-of-range field, or a field whose type is not ``OperandReconstructable`` is a cheap miss. Returns false on any miss.
    func reflectionGraftAttempt() -> Bool {
        guard let (parentIndex, parent) = corpus.pickParent(random: randomUnit()) else {
            return false
        }
        guard let word = comparisonPool.drawValue(sitePick: randomUnit(), valuePick: randomUnit()) else {
            return false
        }
        let fieldIndex = Int(prng.next(upperBound: UInt64(FuzzTunables.reflectionGraftPositionSpan)))
        guard case let .success(anyParent, _, _) = Materializer.materializeAny(
            erasedGen,
            prefix: parent.sequence,
            mode: .exact
        ),
            let parentValue = anyParent as? Output
        else {
            return false
        }
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
        evaluate(injectedCandidate(sequence: sequence, tree: tree, value: value, parent: (parentIndex, parent)))
        return true
    }

    /// Overwrites one or several tag-compatible value entries of a corpus parent's flat sequence with the same harvested comparison operand and evaluates the result as an ordinary mutation candidate.
    ///
    /// This is the trace-cmp path that needs no reflection: the harvest names the operand but not the draw that fed the comparison (either side may be a generated value or the constant it was checked against), so a tag group that can encode the operand is drawn uniformly, and targets uniformly among that group's value entries whose declared range contains the encoding. The slot count is drawn per attempt: a single slot serves the magic-constant gate, while writing the same operand into several slots of one tag group is the agreement move. A property whose precondition demands that many components match (indistinguishability of two independently drawn states, for example) is climbed one comparison at a time by single slots but only satisfied when the matching positions agree at once. Multi-slot writes never mix tags: agreement is the same kind of value in the same kind of place. Overwriting in place preserves the sequence's length and structure, so the candidate rides the normal guided-materialization path; a value that fed a later structural decision diverges into its fallback handling like any other mutation. Integer tags only: strings, dates, and floating-point choices have no positional correspondence with a 64-bit operand word.
    func comparandSubstitutionAttempt() -> Bool {
        guard let (parentIndex, parent) = corpus.pickParent(random: randomUnit()),
              let word = comparisonPool.drawValue(sitePick: randomUnit(), valuePick: randomUnit())
        else {
            return false
        }
        // A test-built entry has no layout; the scan it costs is paid only there.
        let layout = parent.mutationLayout ?? FuzzMutator.structuralLayout(of: parent.sequence)
        let encodableTags = layout.tags.filter { $0.operandBitPattern(fromWord: word) != nil }
        guard encodableTags.isEmpty == false else {
            return false
        }
        let tag = encodableTags[Int(prng.next(upperBound: UInt64(encodableTags.count)))]
        let key = Self.comparandKey(word: word, parentHash: parent.hash, tag: tag)
        // The allowance follows the tag group's size, read off the layout so a retired source still costs no walk; the same value is recomputed at every charge, so the table stores no allowance.
        let slotCount = layout.tags.firstIndex(of: tag).map { layout.tagSlotCounts[$0] } ?? 1
        let allowance = FuzzTunables.comparandOperandEnergy(forSlotCount: slotCount)
        guard operandEnergy.hasEnergy(key, initial: allowance) else {
            return false
        }
        guard let mutated = comparandSubstitutionCandidate(parent: parent, layout: layout, tag: tag, word: word) else {
            // No slot of this group can take the operand. Charged as a barren draw, or the key would be redrawn and walked forever without ever reaching the evaluation that spends its energy.
            operandEnergy.note(key, yielded: false, initial: allowance)
            return false
        }

        var yielded = false
        if let candidate = childCandidate(
            from: mutated,
            parent: parent,
            parentIndex: parentIndex,
            armsMask: 0,
            origin: .comparandSubstitution
        ) {
            let evaluation = evaluate(candidate)
            // A yield is admission or a failure. Admission alone would retire the arm too early: its purpose is to satisfy a precondition that a fault sits behind, and satisfying one need not light an edge the corpus admits for.
            yielded = evaluation.admission.isAdmitted || evaluation.verdict?.isFailure == true
        }
        operandEnergy.note(key, yielded: yielded, initial: allowance)
        return true
    }

    /// Writes `word` over one or several of `parent`'s value entries of `tag`, or nothing when no entry of that tag can hold the encoding.
    ///
    /// The pool draw is memoryless, so an unbounded arm resamples the same operand against the same parent indefinitely: on the Etna STLC type-based workload 97.7% of substitution candidates were sequences the run had already evaluated, each materialized in full before the duplicate check could see it. On IFC the arm spent 254 million of the run's billion mutation attempts to the same end. ``comparandSubstitutionAttempt()`` bounds that with ``OperandEnergyTable`` keyed on the operand, the parent, and the tag group, and consults it before calling here, because this walk over every value position of the parent was 9.2% of IFC's evaluated cases when a retired source only discovered its retirement afterwards. Keying on the tag group as well lets an operand exhausted against one group still reach the parent's others, which is affordable only because ``FuzzMutator/Layout/tags`` names the groups without a walk.
    func comparandSubstitutionCandidate(
        parent: CorpusEntry,
        layout: FuzzMutator.Layout,
        tag: TypeTag,
        word: UInt64
    ) -> ChoiceSequence? {
        guard let pattern = tag.operandBitPattern(fromWord: word) else {
            return nil
        }
        let sequence = parent.sequence
        var group: [Int] = []
        for index in layout.valueIndices {
            guard case let .value(entry) = sequence[index], entry.choice.tag == tag else {
                continue
            }
            let range = entry.validRange ?? tag.bitPatternRange
            if range.contains(pattern), entry.choice.bitPattern64 != pattern {
                group.append(index)
            }
        }
        guard group.isEmpty == false else {
            return nil
        }
        let slotCount = 1 + Int(prng.next(upperBound: UInt64(min(group.count, FuzzTunables.comparandSubstitutionSlotSpan))))
        // Partial Fisher-Yates over the tag group: the first `slotCount` entries end up a uniform distinct sample.
        for slot in 0 ..< slotCount {
            let pickIndex = slot + Int(prng.next(upperBound: UInt64(group.count - slot)))
            group.swapAt(slot, pickIndex)
        }
        var mutated = sequence
        for index in group[0 ..< slotCount] {
            guard case let .value(entry) = mutated[index] else {
                continue
            }
            mutated[index] = .value(ChoiceSequenceValue.Value(
                choice: ChoiceValue(pattern, tag: tag),
                validRange: entry.validRange,
                isRangeExplicit: entry.isRangeExplicit
            ))
        }
        return mutated
    }

    /// Mixes an operand, its parent, and the tag group into one energy key.
    package static func comparandKey(word: UInt64, parentHash: UInt64, tag: TypeTag) -> UInt64 {
        var mixed = word &* 0x9E37_79B9_7F4A_7C15
        mixed ^= parentHash &* 0xBF58_476D_1CE4_E5B9
        mixed ^= UInt64(tag.rawValue) &* 0x94D0_49BB_1331_11EB
        mixed ^= mixed >> 31
        mixed = mixed &* 0xD6E8_FEB8_6659_FD93
        return mixed ^ (mixed >> 32)
    }

    /// Wraps a reflected candidate for ``evaluate(_:)``, sharing the tail of the reconstructor and graft paths.
    ///
    /// `parent` is nil for a whole-value candidate reflected from the operand alone, and the grafted corpus entry with its index for a field graft. It sources the breadcrumb's parent hash, the recorded generation, and the attribution index, so a graft counts against its parent the same way a normal mutation does. The whole-value path has no parent, so evaluate opens the mutation count for it. The reflected tree travels with the candidate, so it is not rebuilt.
    private func injectedCandidate(
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        value: Output,
        parent: (index: Int, entry: CorpusEntry)?
    ) -> FuzzCandidate<Output> {
        FuzzCandidate(
            sequence: sequence,
            hash: ZobristHash.hash(of: sequence),
            value: value,
            tree: tree,
            convergence: 1.0,
            generation: parent.map { $0.entry.generation + 1 } ?? 0,
            phase: .mutation,
            origin: parent == nil ? .reflectionInjection : .graftInjection,
            parentIndex: parent?.index,
            parentHash: parent?.entry.hash ?? 0,
            armsMask: 0,
            isBoundaryDerived: false
        )
    }
}
