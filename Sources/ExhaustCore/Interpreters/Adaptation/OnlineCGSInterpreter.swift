//
//  OnlineCGSInterpreter.swift
//  Exhaust
//
//  Created by Chris Kolbu on 24/2/2026.
//

/// Online Choice Gradient Sampling interpreter that generates values directly.
///
/// Unlike the eager ``GeneratorTuning`` tuner (which pre-computes all pick weights in a single top-down pass), this interpreter implements the paper's **online, per-value** algorithm (Figure 3.3). At each `pick` encountered during generation, it computes "derivatives" (residual generators after choosing each branch), samples from each derivative to measure fitness, and selects based on those fitness scores.
///
/// This avoids diversity collapse on recursive generators because each derivative has already fixed all choices above it, making deeper sampling tractable.
///
/// The offline tuning pipeline (weight baking, symbolic subdivision) that consumes data from this interpreter is based on Tjoa et al., "Tuning Random Generators for Property-Based Testing" (OOPSLA2, 2025).
package struct OnlineCGSInterpreter<FinalOutput>: ~Copyable, ExhaustIterator {
    public typealias Element = FinalOutput

    // MARK: - Derivative Context

    /// Maximum derivative depth before handlePick skips derivative evaluation and falls back to weighted selection. Derivative composition through sequence boundaries is not supported, so deep picks cannot produce meaningful fitness signal.
    static var maxDerivativeDepth: Int {
        4
    }

    /// An inspectable data structure representing the composition of all outer continuations needed to produce a `FinalOutput` from a local sub-generator. Each ``handlePick`` or ``handleZip`` call pushes a frame; `apply` composes them to build a full derivative.
    ///
    /// This replaces the opaque `DerivativeWrapper` closure chain with a defunctionalized representation, matching the paper's treatment of CGS derivatives as syntactic transformations on the generator data structure (Goldstein, Ch. 3).
    public struct DerivativeContext {
        public private(set) var frames: [DerivativeFrame] = []

        /// Creates an empty derivative context with no frames.
        public init() {}

        /// The structural descent depth: the number of frames excluding `.transform` adapters.
        ///
        /// Depth gates subdivision, halves the derivative sample count per level, and offsets fitness-record fingerprints, all of which measure how deep the target site sits inside binds, zips, and sequences. A `.transform` frame is a value adapter at the same structural level, so counting it would shift those semantics for every `mapped` or zip layer in the generator.
        public var depth: Int {
            frames.reduce(0) { count, frame in
                if case .transform = frame { return count }
                return count + 1
            }
        }

        /// Pushes a derivative frame onto the context stack for deferred CGS weight updates.
        ///
        /// Each frame captures the surrounding generator structure (a bind continuation, zip siblings, or sequence elements) at one level of descent into the generator tree. Callers invoke this as the interpreter recurses through ``ReflectiveOperation`` nodes so that ``apply(_:)`` can later reassemble a complete ``FinalOutput`` generator from a sub-generator at the target choice site.
        public mutating func push(_ frame: DerivativeFrame) {
            frames.append(frame)
        }

        /// Compose all frames onto `gen` to produce a full `FinalOutput` generator.
        ///
        /// Frames are stored in push order (oldest first). `apply` iterates in reverse (newest/innermost first) to match the closure chain's nesting: `gen.bind(innerCont).bind(outerCont).map(cast)`.
        ///
        /// This composition defines the derivative's semantics. The hot sampling path (`rolloutSample`) interprets the frames directly instead of constructing this generator — building and re-interpreting the bind tower for every sample costs about 20% of warmup sampling throughput.
        public func apply(
            _ gen: AnyGenerator
        ) throws -> Generator<FinalOutput> {
            var current = gen
            for frame in frames.reversed() {
                switch frame {
                    case let .bind(continuation), let .transform(continuation):
                        current = try current.bind { try continuation($0) }

                    case let .zipComponent(index, completed, allGenerators, continuation):
                        let capturedIndex = index
                        let capturedCompleted = completed
                        let capturedGenerators = allGenerators
                        current = try current.bind { componentResult -> AnyGenerator in
                            var gens = ContiguousArray<AnyGenerator>()
                            gens.reserveCapacity(capturedGenerators.count)
                            for (j, g) in capturedGenerators.enumerated() {
                                if j < capturedIndex {
                                    gens.append(.pure(capturedCompleted[j]))
                                } else if j == capturedIndex {
                                    gens.append(.pure(componentResult))
                                } else {
                                    gens.append(g)
                                }
                            }
                            return AnyGenerator.impure(
                                operation: .zip(gens),
                                continuation: { .pure($0) }
                            )
                        }.bind { zipResult in
                            try continuation(zipResult)
                        }

                    case let .sequenceElement(index, completed, totalCount, elementGen, continuation):
                        let capturedIndex = index
                        let capturedCompleted = completed
                        let capturedElementGen = elementGen
                        let capturedTotalCount = totalCount
                        current = try current.bind { elementResult -> AnyGenerator in
                            var gens = ContiguousArray<AnyGenerator>()
                            gens.reserveCapacity(capturedTotalCount)
                            for j in 0 ..< capturedTotalCount {
                                if j < capturedIndex {
                                    gens.append(.pure(capturedCompleted[j]))
                                } else if j == capturedIndex {
                                    gens.append(.pure(elementResult))
                                } else {
                                    gens.append(capturedElementGen)
                                }
                            }
                            return AnyGenerator.impure(
                                operation: .zip(gens),
                                continuation: { .pure($0) }
                            )
                        }.bind { arrayResult in
                            try continuation(arrayResult)
                        }
                }
            }
            return current.map { $0 as! FinalOutput }
        }
    }

    /// One layer of the derivative context stack, recording how to reconstruct a full generator from a single choice site's sub-generator.
    ///
    /// During CGS derivative evaluation, the interpreter descends into a specific choice site. Each level of descent pushes a frame that captures the surrounding context (bind continuation or zip siblings) so that ``DerivativeContext/apply(_:)`` can reassemble the complete generator by replaying the frames in reverse.
    public enum DerivativeFrame {
        /// A bind continuation encountered on the path to the target choice site.
        case bind(continuation: (Any) throws -> AnyGenerator)

        /// A reified value transform (`.transform(.map)` or `.transform(.isomorph)`) encountered on the path to the target choice site. Interpreted identically to `.bind`, but excluded from ``DerivativeContext/depth`` because it adapts the value at the same structural level rather than descending a level.
        case transform(continuation: (Any) throws -> AnyGenerator)

        /// A zip component: the target site is inside the `index`-th child of a zip. `completed` holds already-generated values for earlier children, `allGenerators` holds all children's generators, and `continuation` is the downstream bind.
        case zipComponent(
            index: Int,
            completed: [Any],
            allGenerators: ContiguousArray<AnyGenerator>,
            continuation: (Any) throws -> AnyGenerator
        )

        /// A sequence element: the target site is inside element `index` of a sequence of `totalCount` elements. `completed` holds already-generated values for earlier elements, `elementGen` is the generator for remaining elements, and `continuation` is the downstream bind that receives the assembled array.
        case sequenceElement(
            index: Int,
            completed: [Any],
            totalCount: Int,
            elementGen: AnyGenerator,
            continuation: (Any) throws -> AnyGenerator
        )
    }

    let generator: Generator<FinalOutput>
    private var context: GenerationContext

    // CGS-specific fields
    private let predicate: (FinalOutput) -> Bool
    private let sampleCount: UInt64
    private var cgsState: CGSState

    struct CGSState: ~Copyable {
        var samplingPRNG: Xoshiro256
        var fitnessAccumulator: FitnessAccumulator?
        var subdivisionThresholds: CGSSubdivisionThresholds
    }

    /// Creates an online CGS interpreter for the given generator and predicate, with optional derivative sampling count, seed, run cap, fitness accumulator, and subdivision thresholds.
    public init(
        _ generator: Generator<FinalOutput>,
        predicate: @escaping (FinalOutput) -> Bool,
        sampleCount: UInt64 = 50,
        seed: UInt64? = nil,
        maxRuns: UInt64? = nil,
        fitnessAccumulator: FitnessAccumulator? = nil,
        subdivisionThresholds: CGSSubdivisionThresholds = .default
    ) {
        self.generator = generator
        self.predicate = predicate
        self.sampleCount = sampleCount
        let baseSeed: UInt64
        if let seed {
            baseSeed = seed
        } else {
            var rng = SystemRandomNumberGenerator()
            baseSeed = rng.next()
        }
        var samplingPRNG = Xoshiro256(seed: baseSeed)
        samplingPRNG.jump()
        cgsState = CGSState(
            samplingPRNG: samplingPRNG,
            fitnessAccumulator: fitnessAccumulator,
            subdivisionThresholds: subdivisionThresholds
        )
        context = .init(
            maxRuns: maxRuns ?? 100,
            baseSeed: baseSeed,
            isFixed: false,
            size: 0,
            prng: Xoshiro256(seed: baseSeed)
        )
    }

    // MARK: - Iterator

    public mutating func next() throws -> Element? {
        guard context.runs < context.maxRuns else {
            context.printClassifications()
            return nil
        }

        // Per-run seed derivation: each run gets an independent PRNG
        let runSeed = Xoshiro256.deriveSeed(from: context.baseSeed, at: context.runs)
        context.prng = Xoshiro256(seed: runSeed)
        cgsState.samplingPRNG = Xoshiro256(seed: runSeed)
        cgsState.samplingPRNG.jump()

        let derivativeContext = DerivativeContext()

        defer {
            context.runs += 1
        }

        return try Self.generateRecursive(
            generator,
            with: (),
            context: &context,
            predicate: predicate,
            sampleCount: sampleCount,
            cgsState: &cgsState,
            derivativeContext: derivativeContext
        )
    }

    // MARK: - Recursive Engine

    static func generateRecursive<Output>(
        _ gen: Generator<Output>,
        with inputValue: some Any,
        context: inout GenerationContext,
        predicate: @escaping (FinalOutput) -> Bool,
        sampleCount: UInt64,
        cgsState: inout CGSState,
        derivativeContext: DerivativeContext
    ) throws -> Output? {
        switch gen {
            case let .pure(value):
                return value

            case let .impure(operation: .contramap(_, nextGen), continuation):
                return try handleContramap(
                    nextGen: nextGen, continuation: continuation,
                    inputValue: inputValue, context: &context,
                    predicate: predicate, sampleCount: sampleCount,
                    cgsState: &cgsState, derivativeContext: derivativeContext
                )

            case let .impure(operation: .prune(nextGen), continuation):
                return try handlePrune(
                    nextGen: nextGen, continuation: continuation,
                    inputValue: inputValue, context: &context,
                    predicate: predicate, sampleCount: sampleCount,
                    cgsState: &cgsState, derivativeContext: derivativeContext
                )

            case let .impure(operation: .pick(choices, totalWeight), continuation):
                return try handlePick(
                    choices, totalWeight: totalWeight,
                    continuation: continuation,
                    inputValue: inputValue,
                    context: &context,
                    predicate: predicate,
                    sampleCount: sampleCount,
                    cgsState: &cgsState,
                    derivativeContext: derivativeContext
                )

            case let .impure(operation: .chooseBits(min, max, tag, isRangeExplicit, scaling, _), continuation):
                return try handleChooseBits(
                    min: min, max: max, tag: tag,
                    isRangeExplicit: isRangeExplicit, scaling: scaling,
                    continuation: continuation,
                    inputValue: inputValue, context: &context,
                    predicate: predicate, sampleCount: sampleCount,
                    cgsState: &cgsState, derivativeContext: derivativeContext
                )

            case let .impure(operation: .sequence(lengthGen, elementGen), continuation):
                return try handleSequence(
                    lengthGen: lengthGen, elementGen: elementGen,
                    continuation: continuation,
                    inputValue: inputValue, context: &context,
                    predicate: predicate, sampleCount: sampleCount,
                    cgsState: &cgsState, derivativeContext: derivativeContext
                )

            case let .impure(operation: .zip(generators, _), continuation):
                return try handleZip(
                    generators,
                    continuation: continuation,
                    inputValue: inputValue,
                    context: &context,
                    predicate: predicate,
                    sampleCount: sampleCount,
                    cgsState: &cgsState,
                    derivativeContext: derivativeContext
                )

            case let .impure(operation: .just(value), continuation):
                return try runContinuation(
                    result: value,
                    continuation: continuation,
                    inputValue: inputValue,
                    context: &context,
                    predicate: predicate,
                    sampleCount: sampleCount,
                    cgsState: &cgsState,
                    derivativeContext: derivativeContext
                )

            case .impure(operation: .getSize, let continuation):
                let size = SharedInterpreterHelpers.consumeSize(&context)
                return try runContinuation(
                    result: size,
                    continuation: continuation,
                    inputValue: inputValue,
                    context: &context,
                    predicate: predicate,
                    sampleCount: sampleCount,
                    cgsState: &cgsState,
                    derivativeContext: derivativeContext
                )

            case let .impure(operation: .resize(newSize, gen), continuation):
                return try handleResize(
                    newSize: newSize, gen: gen,
                    continuation: continuation,
                    inputValue: inputValue, context: &context,
                    predicate: predicate, sampleCount: sampleCount,
                    cgsState: &cgsState, derivativeContext: derivativeContext
                )

            case let .impure(operation: .filter(gen, _, _, filterPredicate, sourceLocation), continuation):
                return try handleFilter(
                    gen: gen, filterPredicate: filterPredicate,
                    sourceLocation: sourceLocation,
                    continuation: continuation,
                    inputValue: inputValue, context: &context,
                    predicate: predicate, sampleCount: sampleCount,
                    cgsState: &cgsState, derivativeContext: derivativeContext
                )

            case let .impure(operation: .classify(gen, fingerprint, classifiers), continuation):
                return try handleClassify(
                    gen: gen, fingerprint: fingerprint, classifiers: classifiers,
                    continuation: continuation,
                    inputValue: inputValue, context: &context,
                    predicate: predicate, sampleCount: sampleCount,
                    cgsState: &cgsState, derivativeContext: derivativeContext
                )

            case let .impure(operation: .transform(kind, inner), continuation):
                return try handleTransform(
                    kind: kind, inner: inner,
                    continuation: continuation,
                    inputValue: inputValue, context: &context,
                    predicate: predicate, sampleCount: sampleCount,
                    cgsState: &cgsState, derivativeContext: derivativeContext
                )

            case let .impure(operation: .unique(gen, _, _), continuation):
                return try handleUnique(
                    gen: gen,
                    continuation: continuation,
                    inputValue: inputValue, context: &context,
                    predicate: predicate, sampleCount: sampleCount,
                    cgsState: &cgsState, derivativeContext: derivativeContext
                )
        }
    }
}
