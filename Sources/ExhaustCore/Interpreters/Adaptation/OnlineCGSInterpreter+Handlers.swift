//
//  OnlineCGSInterpreter+Handlers.swift
//  Exhaust
//

// MARK: - Case Handlers

//
// Every non-trivial case body lives in an `@inline(__always)` handler rather than inline in the switch. See the Case Handlers note in ValueInterpreter for the debug stack-frame rationale; this interpreter runs during filter tuning, where nested filters stack one tuning interpretation per nesting level, so its frame size multiplies twice over.

extension OnlineCGSInterpreter {
    @inline(__always)
    static func handleContramap<Output>(
        nextGen: AnyGenerator,
        continuation: (Any) throws -> AnyGenerator,
        inputValue: some Any,
        context: inout GenerationContext,
        predicate: @escaping (FinalOutput) -> Bool,
        sampleCount: UInt64,
        cgsState: inout CGSState,
        derivativeContext: DerivativeContext
    ) throws -> Output? {
        guard let result = try generateRecursive(
            nextGen,
            with: inputValue,
            context: &context,
            predicate: predicate,
            sampleCount: sampleCount,
            cgsState: &cgsState,
            derivativeContext: derivativeContext
        ) else { return nil }
        return try runContinuation(
            result: result,
            continuation: continuation,
            inputValue: inputValue,
            context: &context,
            predicate: predicate,
            sampleCount: sampleCount,
            cgsState: &cgsState,
            derivativeContext: derivativeContext
        )
    }

    @inline(__always)
    static func handlePrune<Output>(
        nextGen: AnyGenerator,
        continuation: (Any) throws -> AnyGenerator,
        inputValue: some Any,
        context: inout GenerationContext,
        predicate: @escaping (FinalOutput) -> Bool,
        sampleCount: UInt64,
        cgsState: inout CGSState,
        derivativeContext: DerivativeContext
    ) throws -> Output? {
        guard let wrappedValue =
            InterpreterWrapperHandlers.unwrapPruneInput(inputValue)
        else {
            return nil
        }
        guard let result = try generateRecursive(
            nextGen,
            with: wrappedValue,
            context: &context,
            predicate: predicate,
            sampleCount: sampleCount,
            cgsState: &cgsState,
            derivativeContext: derivativeContext
        ) else { return nil }
        return try runContinuation(
            result: result,
            continuation: continuation,
            inputValue: inputValue,
            context: &context,
            predicate: predicate,
            sampleCount: sampleCount,
            cgsState: &cgsState,
            derivativeContext: derivativeContext
        )
    }

    @inline(__always)
    static func handleChooseBits<Output>(
        min: UInt64,
        max: UInt64,
        tag: TypeTag,
        isRangeExplicit: Bool,
        scaling: ChooseBitsScaling?,
        continuation: @escaping (Any) throws -> AnyGenerator,
        inputValue: some Any,
        context: inout GenerationContext,
        predicate: @escaping (FinalOutput) -> Bool,
        sampleCount: UInt64,
        cgsState: inout CGSState,
        derivativeContext: DerivativeContext
    ) throws -> Output? {
        // Warmup-only subdivision (never baked). A large-range chooseBits that the pre-pass `subdivideForCGS` left raw — a standalone scalar; the pre-pass only subdivides sequence lengths, plus element gens on the relaxed path — is split into a pick here so derivative sampling and vocabulary elimination can bias it toward predicate-satisfying subranges over the warmup. That biasing raises the valid-sample rate, which is what gives the surrounding bakeable picks a usable fitness signal for sparse filters.
        //
        // These synthesized picks are intentionally never baked: `bakeWeights` walks the original generator (default thresholds, to keep the choice-tree structure that replay and reduction depend on) or the pre-pass subdivided generator (relaxed), and neither contains this on-the-fly pick. A chooseBits cannot carry CGS weights in the final generator without becoming a pick, which would break replay structural compatibility — so a standalone scalar's own tuning is warmup-only by design, and `.rejectionSampling` is the right strategy for such filters. This is not dead code.
        //
        // The fingerprint combines the range and tag with the CGS-only structural path. This keeps equal chooseBits domains at different generator positions from sharing fitness while allowing repeated sequence elements to reuse their element-template site. A per-process value suffices because these records never leave the warmup.
        if derivativeContext.depth < cgsState.subdivisionThresholds.maximumDerivativeDepth,
           max >= min,
           (min ... max).saturatingCount >= cgsState.subdivisionThresholds.minimumRangeSize,
           let choices = SharedInterpreterHelpers.subdivideChooseBits(
               lower: min, upper: max, tag: tag,
               isRangeExplicit: isRangeExplicit, scaling: scaling,
               makeFingerprint: {
                   var fingerprint = Xoshiro256.fold(min, mixing: max)
                   fingerprint = Xoshiro256.fold(fingerprint, mixing: UInt64(bitPattern: Int64(tag.hashValue)))
                   fingerprint = Xoshiro256.fold(
                       fingerprint,
                       mixing: derivativeContext.sitePathFingerprint
                   )
                   return fingerprint
               }
           )
        {
            let synthesizedPick: Generator<Output> = .impure(
                operation: .pick(choices: choices, totalWeight: choices.reduce(0) { $0 &+ $1.weight }),
                continuation: continuation
            )

            return try generateRecursive(
                synthesizedPick,
                with: inputValue,
                context: &context,
                predicate: predicate,
                sampleCount: sampleCount,
                cgsState: &cgsState,
                derivativeContext: derivativeContext
            )
        }
        let effectiveRange: ClosedRange<UInt64>
        if let scaling {
            let size = SharedInterpreterHelpers.currentSize(&context)
            effectiveRange = Gen.applyScaling(
                min: min, max: max, tag: tag, scaling: scaling, size: size
            )
        } else {
            effectiveRange = min ... max
        }
        let rawBits = context.prng.next(in: effectiveRange)
        let randomBits = tag.isFloatingPoint
            ? tag.linearlyDistributed(rawBits: rawBits, in: effectiveRange)
            : rawBits
        return try runContinuation(
            result: randomBits,
            continuation: continuation,
            inputValue: inputValue,
            context: &context,
            predicate: predicate,
            sampleCount: sampleCount,
            cgsState: &cgsState,
            derivativeContext: derivativeContext
        )
    }

    @inline(__always)
    static func handleSequence<Output>(
        lengthGen: Generator<UInt64>,
        elementGen: AnyGenerator,
        continuation: @escaping (Any) throws -> AnyGenerator,
        inputValue: some Any,
        context: inout GenerationContext,
        predicate: @escaping (FinalOutput) -> Bool,
        sampleCount: UInt64,
        cgsState: inout CGSState,
        derivativeContext: DerivativeContext
    ) throws -> Output? {
        // Length generator: skip derivative evaluation — the length produces UInt64, not FinalOutput, so derivatives can't compose through. Depth >= 4 triggers handlePick's fast path.
        var lengthDerivativeContext = DerivativeContext()
        for _ in 0 ..< Self.maxDerivativeDepth {
            lengthDerivativeContext.push(.bind(continuation: { .pure($0) }))
        }
        guard let length = try generateRecursive(
            lengthGen,
            with: inputValue,
            context: &context,
            predicate: predicate,
            sampleCount: sampleCount,
            cgsState: &cgsState,
            derivativeContext: lengthDerivativeContext
        ) else {
            return nil
        }

        let elementCount = try SharedInterpreterHelpers.sequenceElementCount(length)
        var results: [Any] = []
        results.reserveCapacity(elementCount)
        for _ in 0 ..< elementCount {
            var elementContext = derivativeContext
            elementContext.descendSitePath(through: .sequenceElement)
            elementContext.push(.sequenceElement(
                index: results.count,
                completed: results,
                totalCount: elementCount,
                elementGen: elementGen,
                continuation: { try continuation($0).erase() }
            ))

            guard let result = try generateRecursive(
                elementGen,
                with: inputValue,
                context: &context,
                predicate: predicate,
                sampleCount: sampleCount,
                cgsState: &cgsState,
                derivativeContext: elementContext
            ) else {
                return nil
            }
            results.append(result)
        }
        return try runContinuation(
            result: results,
            continuation: continuation,
            inputValue: inputValue,
            context: &context,
            predicate: predicate,
            sampleCount: sampleCount,
            cgsState: &cgsState,
            derivativeContext: derivativeContext
        )
    }

    @inline(__always)
    static func handleResize<Output>(
        newSize: UInt64,
        gen: AnyGenerator,
        continuation: (Any) throws -> AnyGenerator,
        inputValue: some Any,
        context: inout GenerationContext,
        predicate: @escaping (FinalOutput) -> Bool,
        sampleCount: UInt64,
        cgsState: inout CGSState,
        derivativeContext: DerivativeContext
    ) throws -> Output? {
        let previousSizeOverride = context.sizeOverride
        let innerResult: Any?
        do {
            context.sizeOverride = newSize
            defer { context.sizeOverride = previousSizeOverride }
            innerResult = try generateRecursive(
                gen,
                with: inputValue,
                context: &context,
                predicate: predicate,
                sampleCount: sampleCount,
                cgsState: &cgsState,
                derivativeContext: derivativeContext
            )
        }
        guard let innerResult else { return nil }
        return try runContinuation(
            result: innerResult,
            continuation: continuation,
            inputValue: inputValue,
            context: &context,
            predicate: predicate,
            sampleCount: sampleCount,
            cgsState: &cgsState,
            derivativeContext: derivativeContext
        )
    }

    @inline(__always)
    static func handleFilter<Output>(
        gen: AnyGenerator,
        filterPredicate: (Any) -> Bool,
        sourceLocation: FilterSourceLocation,
        continuation: (Any) throws -> AnyGenerator,
        inputValue: some Any,
        context: inout GenerationContext,
        predicate: @escaping (FinalOutput) -> Bool,
        sampleCount: UInt64,
        cgsState: inout CGSState,
        derivativeContext: DerivativeContext
    ) throws -> Output? {
        // Warmup uses the untuned base so the fitness it collects — and the tuning it produces — depend only on the seed, not on prior cache state.
        let tunedGen = gen

        var attempts = 0 as UInt64
        while attempts < GenerationContext.maxFilterRuns {
            guard let result = try generateRecursive(
                tunedGen,
                with: inputValue,
                context: &context,
                predicate: predicate,
                sampleCount: sampleCount,
                cgsState: &cgsState,
                derivativeContext: derivativeContext
            ) else { return nil }

            if filterPredicate(result) {
                return try runContinuation(
                    result: result,
                    continuation: continuation,
                    inputValue: inputValue,
                    context: &context,
                    predicate: predicate,
                    sampleCount: sampleCount,
                    cgsState: &cgsState,
                    derivativeContext: derivativeContext
                )
            }
            attempts += 1
        }
        sourceLocation.onBudgetExhausted?()
        throw GeneratorError.sparseValidityCondition
    }

    @inline(__always)
    static func handleClassify<Output>(
        gen: AnyGenerator,
        fingerprint: UInt64,
        classifiers: [(label: String, predicate: (Any) -> Bool)],
        continuation: (Any) throws -> AnyGenerator,
        inputValue: some Any,
        context: inout GenerationContext,
        predicate: @escaping (FinalOutput) -> Bool,
        sampleCount: UInt64,
        cgsState: inout CGSState,
        derivativeContext: DerivativeContext
    ) throws -> Output? {
        guard let result = try generateRecursive(
            gen,
            with: inputValue,
            context: &context,
            predicate: predicate,
            sampleCount: sampleCount,
            cgsState: &cgsState,
            derivativeContext: derivativeContext
        ) else { return nil }
        for (label, classifier) in classifiers where classifier(result) {
            var byLabel = context.classifications[fingerprint, default: [:]]
            byLabel[label, default: []].insert(context.runs)
            context.classifications[fingerprint] = byLabel
        }
        return try runContinuation(
            result: result,
            continuation: continuation,
            inputValue: inputValue,
            context: &context,
            predicate: predicate,
            sampleCount: sampleCount,
            cgsState: &cgsState,
            derivativeContext: derivativeContext
        )
    }

    @inline(__always)
    static func handleTransform<Output>(
        kind: TransformKind,
        inner: AnyGenerator,
        continuation: @escaping (Any) throws -> AnyGenerator,
        inputValue: some Any,
        context: inout GenerationContext,
        predicate: @escaping (FinalOutput) -> Bool,
        sampleCount: UInt64,
        cgsState: inout CGSState,
        derivativeContext: DerivativeContext
    ) throws -> Output? {
        let result: Any
        switch kind {
            case let .map(forward, _, _, _), let .isomorph(forward, _, _, _):
                // Push the forward transform as a frame so derivative rollouts inside `inner` apply it. Without this, a rollout crossing the transform boundary hands the untransformed inner value (for example `[Character]` instead of `String`) to outer frames, which trap on their continuation casts.
                var innerContext = derivativeContext
                innerContext.descendSitePath(through: .transformInner)
                innerContext.push(.transform(continuation: { innerValue in
                    try continuation(forward(innerValue)).erase()
                }))
                guard let innerValue = try generateRecursive(
                    inner,
                    with: inputValue,
                    context: &context,
                    predicate: predicate,
                    sampleCount: sampleCount,
                    cgsState: &cgsState,
                    derivativeContext: innerContext
                ) else { return nil }
                result = try forward(innerValue)
            case let .bind(_, forward, _, _, _):
                var innerContext = derivativeContext
                innerContext.descendSitePath(through: .bindInner)
                innerContext.push(.bind(continuation: { innerValue in
                    let boundGen = try forward(innerValue)
                    return try boundGen.bind { boundValue in
                        try continuation(boundValue).erase()
                    }
                }))
                guard let innerValue = try generateRecursive(
                    inner,
                    with: inputValue,
                    context: &context,
                    predicate: predicate,
                    sampleCount: sampleCount,
                    cgsState: &cgsState,
                    derivativeContext: innerContext
                ) else { return nil }
                let boundGen = try forward(innerValue)
                var boundContext = derivativeContext
                boundContext.descendSitePath(through: .bindBound)
                guard let boundValue = try generateRecursive(
                    boundGen,
                    with: inputValue,
                    context: &context,
                    predicate: predicate,
                    sampleCount: sampleCount,
                    cgsState: &cgsState,
                    derivativeContext: boundContext
                ) else { return nil }
                result = boundValue
            case let .metamorphic(transforms, _):
                let savedState = (context.prng.seed, context.prng.currentState)
                var innerContext = derivativeContext
                innerContext.descendSitePath(through: .transformInner)
                guard let original = try generateRecursive(
                    inner,
                    with: inputValue,
                    context: &context,
                    predicate: predicate,
                    sampleCount: sampleCount,
                    cgsState: &cgsState,
                    derivativeContext: innerContext
                ) else { return nil }
                var results: [Any] = [original]
                results.reserveCapacity(transforms.count + 1)
                // Copies replay from the original's PRNG state; tuning does not own generation-time uniqueness state.
                for transform in transforms {
                    context.prng = Xoshiro256(seed: savedState.0, state: savedState.1)
                    guard let copy = try generateRecursive(
                        inner,
                        with: inputValue,
                        context: &context,
                        predicate: predicate,
                        sampleCount: sampleCount,
                        cgsState: &cgsState,
                        derivativeContext: innerContext
                    ) else { return nil }
                    try results.append(transform(copy))
                }
                result = results
        }
        return try runContinuation(
            result: result,
            continuation: continuation,
            inputValue: inputValue,
            context: &context,
            predicate: predicate,
            sampleCount: sampleCount,
            cgsState: &cgsState,
            derivativeContext: derivativeContext
        )
    }

    /// Treats uniqueness operations as transparent while collecting CGS fitness data.
    ///
    /// Online CGS discards every warm-up value; the tuned generator later runs through ``ValueAndChoiceTreeInterpreter``, which owns the per-site operative-hash sets. Maintaining deduplication state here would make tuning depend on whether the output happens to be `Hashable` and could exhaust a finite domain before its fitness data converges. Tuning may change pick weights, but it must neither consume nor enforce generation-time uniqueness state.
    @inline(__always)
    static func handleUnique<Output>(
        gen: AnyGenerator,
        continuation: (Any) throws -> AnyGenerator,
        inputValue: some Any,
        context: inout GenerationContext,
        predicate: @escaping (FinalOutput) -> Bool,
        sampleCount: UInt64,
        cgsState: inout CGSState,
        derivativeContext: DerivativeContext
    ) throws -> Output? {
        guard let result = try generateRecursive(
            gen,
            with: inputValue,
            context: &context,
            predicate: predicate,
            sampleCount: sampleCount,
            cgsState: &cgsState,
            derivativeContext: derivativeContext
        ) else { return nil }
        return try runContinuation(
            result: result,
            continuation: continuation,
            inputValue: inputValue,
            context: &context,
            predicate: predicate,
            sampleCount: sampleCount,
            cgsState: &cgsState,
            derivativeContext: derivativeContext
        )
    }

    // MARK: - Run Continuation

    @inline(__always)
    static func runContinuation<Output>(
        result: Any,
        continuation: (Any) throws -> AnyGenerator,
        inputValue: some Any,
        context: inout GenerationContext,
        predicate: @escaping (FinalOutput) -> Bool,
        sampleCount: UInt64,
        cgsState: inout CGSState,
        derivativeContext: DerivativeContext
    ) throws -> Output? {
        let nextGen = try continuation(result)
        var continuationContext = derivativeContext
        continuationContext.descendSitePath(through: .continuation)
        guard let finalValue = try generateRecursive(
            nextGen,
            with: inputValue,
            context: &context,
            predicate: predicate,
            sampleCount: sampleCount,
            cgsState: &cgsState,
            derivativeContext: continuationContext
        ) else {
            return nil
        }
        return finalValue as? Output
    }

    // MARK: - Pick (CGS Core)

    @inline(__always)
    static func handlePick<Output>(
        _ choices: ContiguousArray<ReflectiveOperation.PickTuple>,
        totalWeight: UInt64,
        continuation: @escaping (Any) throws -> AnyGenerator,
        inputValue: some Any,
        context: inout GenerationContext,
        predicate: @escaping (FinalOutput) -> Bool,
        sampleCount: UInt64,
        cgsState: inout CGSState,
        derivativeContext: DerivativeContext
    ) throws -> Output? {
        // Fast path: single choice or deep pick — skip derivative evaluation.
        // Without .sequenceElement frames, derivative context cannot compose through sequence boundaries, so deep picks must fall back to weighted selection.
        let effectiveSampleCount = Swift.max(2, sampleCount >> derivativeContext.depth)
        if choices.count == 1 || derivativeContext.depth >= Self.maxDerivativeDepth {
            guard let selectedChoice = WeightedPickSelection.draw(
                from: choices, totalWeight: totalWeight, using: &context.prng
            ) else {
                return nil
            }
            _ = context.prng.next()

            var branchContext = derivativeContext
            branchContext.descendSitePath(
                through: .pickBranch,
                discriminator: Xoshiro256.fold(
                    selectedChoice.fingerprint,
                    mixing: selectedChoice.id
                )
            )
            branchContext.push(.bind(continuation: { try continuation($0).erase() }))

            guard let result = try generateRecursive(
                selectedChoice.generator,
                with: inputValue,
                context: &context,
                predicate: predicate,
                sampleCount: sampleCount,
                cgsState: &cgsState,
                derivativeContext: branchContext
            ) else {
                return nil
            }
            return try runContinuation(
                result: result,
                continuation: continuation,
                inputValue: inputValue,
                context: &context,
                predicate: predicate,
                sampleCount: sampleCount,
                cgsState: &cgsState,
                derivativeContext: derivativeContext
            )
        }

        // 0. Vocabulary elimination: skip derivative evaluation for choices that are historically dead (0 fitness after ≥30 observations).
        // Once a choice is rejected enough times, remove it from the proposal distribution to avoid wasting derivative evaluations on known-dead branches.
        //
        // Adapted from the adaptive rejection sampling vocabulary elimination in: Lipkin et al., "Fast Controlled Generation from Language Models with Adaptive Weighted Rejection Sampling", COLM 2025.
        // arXiv:2504.05410
        let currentSize = SharedInterpreterHelpers.currentSize(&context)
        let choiceCount = choices.count
        let minDeadObservations: UInt64 = 30
        // Recursive generators (BST, AVL) reuse the same source-level pick at every depth, producing identical fingerprints. Without depth scoping, vocabulary elimination at the root (where "leaf" is always dead) would kill "leaf" at inner depths too — but inner depths NEED leaves for validity.
        let depthOffset = UInt64(derivativeContext.depth) &* 0x9E37_79B9_7F4A_7C15

        let liveChoiceIndices = liveIndices(
            for: choices,
            records: cgsState.fitnessAccumulator?.records,
            minDeadObservations: minDeadObservations,
            fingerprintOffset: depthOffset
        )

        // Single live choice after elimination — skip derivative evaluation
        if liveChoiceIndices.count == 1 {
            let selectedChoice = choices[liveChoiceIndices[0]]
            _ = context.prng.next()

            var branchContext = derivativeContext
            branchContext.descendSitePath(
                through: .pickBranch,
                discriminator: Xoshiro256.fold(
                    selectedChoice.fingerprint,
                    mixing: selectedChoice.id
                )
            )
            branchContext.push(.bind(continuation: { try continuation($0).erase() }))

            guard let result = try generateRecursive(
                selectedChoice.generator,
                with: inputValue,
                context: &context,
                predicate: predicate,
                sampleCount: sampleCount,
                cgsState: &cgsState,
                derivativeContext: branchContext
            ) else {
                return nil
            }
            return try runContinuation(
                result: result,
                continuation: continuation,
                inputValue: inputValue,
                context: &context,
                predicate: predicate,
                sampleCount: sampleCount,
                cgsState: &cgsState,
                derivativeContext: derivativeContext
            )
        }

        // 1. Compute fitness via interleaved derivative sampling
        //
        // Each sample is a defunctionalized rollout (`rolloutSample`): the branch and each derivative frame are value-walked directly. Sampling in rounds across live choices allows adaptive stopping when the relative ranking is decided, rather than exhausting the full budget per choice independently.
        var fitnesses = ContiguousArray(repeating: UInt64(0), count: choiceCount)
        let minRounds = Swift.min(UInt64(8), effectiveSampleCount)
        var completedRounds: UInt64 = 0

        sampling: for round in 0 ..< effectiveSampleCount {
            completedRounds = round + 1
            for choiceIdx in liveChoiceIndices {
                do {
                    let result = try rolloutSample(
                        branch: choices[choiceIdx].generator,
                        pickContinuation: continuation,
                        frames: derivativeContext.frames,
                        rng: &cgsState.samplingPRNG,
                        size: currentSize
                    )
                    if let value = result, predicate(value) {
                        fitnesses[choiceIdx] += 1
                    }
                } catch {
                    // Sampling failed — count as unsuccessful
                }
            }

            // Adaptive stopping: check if ranking is decided after minimum rounds
            if round + 1 >= minRounds {
                var best: UInt64 = 0
                var secondBest: UInt64 = 0
                var nonZeroCount = 0
                for f in fitnesses {
                    if f > 0 { nonZeroCount += 1 }
                    if f > best {
                        secondBest = best
                        best = f
                    } else if f > secondBest {
                        secondBest = f
                    }
                }
                // All zero — keep sampling, might still find something
                guard best > 0 else { continue }
                // Only one viable choice — ranking is decided
                if nonZeroCount == 1 { break sampling }
                // Leader dominates — ranking is unlikely to change
                if best >= secondBest &* 3 { break sampling }
            }
        }

        // 1b. Record fitness data for live choices only (dead choices are not evaluated and should not accumulate phantom observations)
        if let accumulator = cgsState.fitnessAccumulator {
            for choiceIdx in liveChoiceIndices {
                let choice = choices[choiceIdx]
                accumulator.record(
                    fingerprint: choice.fingerprint &+ depthOffset,
                    choiceID: choice.id,
                    fitness: fitnesses[choiceIdx],
                    observations: completedRounds
                )
            }
        }

        // 2. Build weighted choices — dead choices get weight 0, live choices with all-zero fitness fall back to equal weights
        let allLiveZero = liveChoiceIndices.allSatisfy { fitnesses[$0] == 0 }
        var isLive = ContiguousArray<Bool>(repeating: false, count: choices.count)
        for index in liveChoiceIndices {
            isLive[index] = true
        }
        var weightedChoices = ContiguousArray<ReflectiveOperation.PickTuple>()
        weightedChoices.reserveCapacity(choices.count)
        for (i, choice) in choices.enumerated() {
            weightedChoices.append(ReflectiveOperation.PickTuple(
                fingerprint: choice.fingerprint,
                id: choice.id,
                weight: allLiveZero
                    ? (isLive[i] ? 1 : 0)
                    : fitnesses[i],
                generator: choice.generator
            ))
        }

        // 3. Select branch weighted by fitness
        let weightedTotalWeight = weightedChoices.reduce(0 as UInt64) { $0 &+ $1.weight }
        guard let selectedChoice = WeightedPickSelection.draw(
            from: weightedChoices, totalWeight: weightedTotalWeight, using: &context.prng
        ) else {
            return nil
        }

        // Consume a PRNG value to keep parity with other interpreters
        _ = context.prng.next()

        // 4. Push frame for the selected branch's context
        var branchContext = derivativeContext
        branchContext.descendSitePath(
            through: .pickBranch,
            discriminator: Xoshiro256.fold(
                selectedChoice.fingerprint,
                mixing: selectedChoice.id
            )
        )
        branchContext.push(.bind(continuation: { try continuation($0).erase() }))

        // 5. Recurse on selected choice's generator
        guard let result = try generateRecursive(
            selectedChoice.generator,
            with: inputValue,
            context: &context,
            predicate: predicate,
            sampleCount: sampleCount,
            cgsState: &cgsState,
            derivativeContext: branchContext
        ) else {
            return nil
        }

        // 6. Apply continuation
        return try runContinuation(
            result: result,
            continuation: continuation,
            inputValue: inputValue,
            context: &context,
            predicate: predicate,
            sampleCount: sampleCount,
            cgsState: &cgsState,
            derivativeContext: derivativeContext
        )
    }

    // MARK: - Defunctionalized Rollout Sampling

    /// Completes one derivative sample by value-walking the branch and then interpreting each ``DerivativeFrame`` directly, without constructing the composed generator that ``DerivativeContext/apply(_:)`` builds.
    ///
    /// `apply` defines the semantics this function must match: sampling `derivativeContext.apply(branch.bind(pickContinuation))` visits the same operations in the same order, so PRNG consumption is identical. Reordering the frame interpretation breaks that parity, and with it the seed determinism of warmup fitness data. The difference is purely mechanical: the tower pays closure dispatch, `.pure` boxing, and `.impure` node allocation at every frame layer for every sample, while the rollout allocates only the component arrays the frames themselves require.
    ///
    /// - Returns: The completed value, or `nil` when any sub-generator fails to produce one — a prune rejects, or the final cast to `FinalOutput` fails where `apply`'s tower would trap on its force cast.
    private static func rolloutSample(
        branch: AnyGenerator,
        pickContinuation: (Any) throws -> AnyGenerator,
        frames: [DerivativeFrame],
        rng: inout Xoshiro256,
        size: UInt64
    ) throws -> FinalOutput? {
        guard let branchValue = try CGSDerivativeInterpreter.sample(branch, using: &rng, size: size) else {
            return nil
        }
        guard var current = try CGSDerivativeInterpreter.sample(pickContinuation(branchValue), using: &rng, size: size) else {
            return nil
        }

        // Newest frame first, matching the nesting order `apply` produces: the innermost bind runs immediately after the branch, the oldest frame runs last.
        for frame in frames.reversed() {
            switch frame {
                case let .bind(continuation), let .transform(continuation):
                    guard let next = try CGSDerivativeInterpreter.sample(continuation(current), using: &rng, size: size) else {
                        return nil
                    }
                    current = next

                case let .zipComponent(index, completed, allGenerators, continuation):
                    var components = completed
                    components.reserveCapacity(allGenerators.count)
                    components.append(current)
                    for j in (index + 1) ..< allGenerators.count {
                        guard let sibling = try CGSDerivativeInterpreter.sample(allGenerators[j], using: &rng, size: size) else {
                            return nil
                        }
                        components.append(sibling)
                    }
                    guard let next = try CGSDerivativeInterpreter.sample(continuation(components), using: &rng, size: size) else {
                        return nil
                    }
                    current = next

                case let .sequenceElement(index, completed, totalCount, elementGen, continuation):
                    var elements = completed
                    elements.reserveCapacity(totalCount)
                    elements.append(current)
                    for _ in (index + 1) ..< totalCount {
                        guard let element = try CGSDerivativeInterpreter.sample(elementGen, using: &rng, size: size) else {
                            return nil
                        }
                        elements.append(element)
                    }
                    guard let next = try CGSDerivativeInterpreter.sample(continuation(elements), using: &rng, size: size) else {
                        return nil
                    }
                    current = next
            }
        }
        return current as? FinalOutput
    }

    // MARK: - Vocabulary Elimination

    /// Returns the indices of live choices — those not yet eliminated by vocabulary pruning.
    ///
    /// A choice is eliminated when its observation count reaches `minDeadObservations` and its total fitness is zero. When all choices would be eliminated, all indices are returned (prevents empty pick). When `records` is `nil`, all indices are returned.
    private static func liveIndices(
        for choices: ContiguousArray<ReflectiveOperation.PickTuple>,
        records: [FitnessAccumulator.SiteChoiceKey: FitnessAccumulator.FitnessRecord]?,
        minDeadObservations: UInt64,
        fingerprintOffset: UInt64 = 0
    ) -> ContiguousArray<Int> {
        guard let records else {
            return ContiguousArray(0 ..< choices.count)
        }
        var live = ContiguousArray<Int>()
        live.reserveCapacity(choices.count)
        for (i, choice) in choices.enumerated() {
            let key = FitnessAccumulator.SiteChoiceKey(fingerprint: choice.fingerprint &+ fingerprintOffset, choiceID: choice.id)
            if let record = records[key],
               record.observationCount >= minDeadObservations,
               record.totalFitness == 0
            {
                continue
            }
            live.append(i)
        }
        if live.isEmpty {
            return ContiguousArray(0 ..< choices.count)
        }
        return live
    }

    // MARK: - Zip

    @inline(__always)
    static func handleZip<Output>(
        _ generators: ContiguousArray<AnyGenerator>,
        continuation: @escaping (Any) throws -> AnyGenerator,
        inputValue: some Any,
        context: inout GenerationContext,
        predicate: @escaping (FinalOutput) -> Bool,
        sampleCount: UInt64,
        cgsState: inout CGSState,
        derivativeContext: DerivativeContext
    ) throws -> Output? {
        var results = [Any]()
        results.reserveCapacity(generators.count)

        for (index, generator) in generators.enumerated() {
            var componentContext = derivativeContext
            componentContext.descendSitePath(
                through: .zipComponent,
                discriminator: UInt64(index)
            )
            componentContext.push(.zipComponent(
                index: index,
                completed: results,
                allGenerators: generators,
                continuation: { try continuation($0).erase() }
            ))

            guard let result = try generateRecursive(
                generator,
                with: inputValue,
                context: &context,
                predicate: predicate,
                sampleCount: sampleCount,
                cgsState: &cgsState,
                derivativeContext: componentContext
            ) else {
                throw GeneratorError.choiceTreeConstructionFailed
            }
            results.append(result)
        }
        return try runContinuation(
            result: results,
            continuation: continuation,
            inputValue: inputValue,
            context: &context,
            predicate: predicate,
            sampleCount: sampleCount,
            cgsState: &cgsState,
            derivativeContext: derivativeContext
        )
    }
}
