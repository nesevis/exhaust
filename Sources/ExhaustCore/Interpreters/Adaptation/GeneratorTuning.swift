//
//  GeneratorTuning.swift
//  Exhaust
//
//  Created by Chris Kolbu on 24/2/2026.
//

import Foundation

/// Offline, one-shot tuning that transforms a generator's pick structure using fitness-weighted sampling inspired by Choice Gradient Sampling (CGS).
///
/// Tuning is performed once at creation time via a single top-down recursive pass. The result is a normal `ReflectiveGenerator` with synthesised pick structure whose weights reflect predicate satisfaction rates. Shrinking is unaffected because the reducer operates on `ChoiceTree`/`ChoiceSequence` and is weight-agnostic.
///
/// ## Algorithm
///
/// At every `pick`, each choice is sampled through the continuation pipeline to measure how often the final output satisfies the predicate. The measured success count becomes the choice's weight. Inner generators are recursively tuned using *composed predicates* — the current continuation is folded into the predicate so that inner operations always evaluate against the final output.
///
/// `chooseBits` and `getSize` operations are subdivided into synthesised picks of subranges, then tuned through the pick path.
///
/// The specification-entropy objective and symbolic weight computation are based on Tjoa et al., "Tuning Random Generators for Property-Based Testing" (OOPSLA2, 2025). Exhaust diverges by using convergence-gated batched sampling instead of the paper's fixed sample budget.
public enum GeneratorTuning {
    // MARK: - Context

    final class TuningContext {
        let baseSampleCount: UInt64
        let maxSize: UInt64
        var depth: UInt64 = 0
        var rng: Xoshiro256

        init(baseSampleCount: UInt64, maxSize: UInt64, rng: consuming Xoshiro256) {
            self.baseSampleCount = baseSampleCount
            self.maxSize = maxSize
            self.rng = rng
        }

        /// Sample budget decays linearly with depth as a safety ceiling.
        /// Convergence detection in `measureAndTunePick` typically stops well before this cap, so deeper sites still get meaningful signal.
        var maxSamplesPerSite: UInt64 {
            max(1, baseSampleCount / (1 + depth))
        }
    }

    // MARK: - Convergence Constants

    /// Number of samples per choice in each batch before checking convergence.
    static let convergenceBatchSize: UInt64 = 20

    /// Maximum absolute shift in normalized weights to consider converged.
    static let convergenceThreshold: Double = 0.05

    /// Minimum total samples per choice before convergence checks begin (2 × batchSize).
    static let convergenceMinSamples: UInt64 = 40

    /// Minimum selection probability per choice. Prevents extreme weight ratios from compounding across depth levels, which would collapse rare-but-valid deep paths to near-zero probability. The paper (§4.3, Figure 13) shows that bounding weights to [0.1, 0.9] prevents overfitting and improves output diversity.
    ///
    /// **Caveat for wide picks:** the floor applies per-choice, so a pick with many dead branches pays a cost proportional to `deadBranches / totalBranches`.
    /// Binary picks lose at most ~10% of selection probability to the floor, but e.g. a 20-way pick with 2 valid branches drops valid selection from ~100% to ~36%. If this becomes a problem, scale the fraction inversely with branch count (`weightFloorFraction / choiceCount`) to cap total floor budget at a fixed share of weight regardless of branch count.
    static let weightFloorFraction: Double = 0.1

    // MARK: - Public API

    /// Probes a generator's structure by running it a few times and checking whether the resulting choice trees contain any pick sites. If picks are present, performs full tuning with adaptive smoothing. If not, returns the generator unchanged — tuning has nothing to attach weights to.
    ///
    /// - Parameters:
    ///   - generator: The generator to probe and possibly tune.
    ///   - probeSeed: Seed for the probe runs (default 0).
    ///   - probeRuns: Number of probe generations to inspect (default 10).
    ///   - minPerChoice: Minimum samples per choice at the deepest pick level (default 30).
    ///   - maxSamples: Upper bound on the computed sample count (default 5000).
    ///   - maxRuns: Planned generation volume. When provided, the tuning budget is capped so that tuning doesn't dwarf generation time for small runs.
    ///   - maxSize: Maximum size parameter used when subdividing `getSize`.
    ///   - seed: Optional seed for deterministic tuning.
    ///   - predicate: The property that generated values should satisfy.
    /// - Returns: A tuned generator if picks were found, or the original generator unchanged.
    public static func probeAndTune<Output>(
        _ generator: ReflectiveGenerator<Output>,
        probeSeed: UInt64 = 0,
        probeRuns: UInt64 = 10,
        minPerChoice: UInt64 = 30,
        maxSamples: UInt64 = 5000,
        maxRuns: UInt64? = nil,
        maxSize: UInt64 = 100,
        seed: UInt64? = nil,
        predicate: @escaping (Output) -> Bool
    ) throws -> ReflectiveGenerator<Output> {
        var probe = ValueAndChoiceTreeInterpreter(generator, seed: probeSeed, maxRuns: probeRuns)
        var maxComplexity: UInt64 = 0

        while let (_, tree) = try probe.next() {
            maxComplexity = max(maxComplexity, tree.pickComplexity)
        }

        guard maxComplexity > 0 else { return generator }

        var samples = min(maxSamples, minPerChoice * maxComplexity)

        // Cap tuning budget relative to planned generation volume.
        // Tuning cost should not dwarf generation time — for small runs
        // we only need directionally correct weights, not precise ones.
        // Convergence detection handles the rest.
        if let maxRuns {
            samples = min(samples, max(convergenceMinSamples, maxRuns / 5))
        }

        let tuned = try tune(
            generator,
            samples: samples,
            maxSize: maxSize,
            seed: seed,
            predicate: predicate
        )
        return smoothAdaptively(tuned)
    }

    /// Tunes a generator so that its pick weights reflect predicate satisfaction rates.
    ///
    /// The transformation is eager — the returned generator has its structure fully tuned and can be used with any interpreter.
    ///
    /// - Parameters:
    ///   - generator: The generator to tune.
    ///   - samples: Base number of samples per pick choice (decays with depth).
    ///   - maxSize: Maximum size parameter used when subdividing `getSize`.
    ///   - seed: Optional seed for deterministic tuning.
    ///   - predicate: The property that generated values should satisfy.
    /// - Returns: A tuned generator with weights biased toward predicate satisfaction.
    public static func tune<Output>(
        _ generator: ReflectiveGenerator<Output>,
        samples: UInt64 = 100,
        maxSize: UInt64 = 100,
        seed: UInt64? = nil,
        predicate: @escaping (Output) -> Bool
    ) throws -> ReflectiveGenerator<Output> {
        let rng = if let seed {
            Xoshiro256(seed: seed)
        } else {
            Xoshiro256()
        }
        let context = TuningContext(
            baseSampleCount: samples,
            maxSize: maxSize,
            rng: rng
        )
        return try tuneRecursive(
            generator,
            context: context,
            insideSubdividedChooseBits: false,
            predicate: predicate
        )
    }

    // MARK: - Recursive Engine

    static func tuneRecursive<Output>(
        _ gen: ReflectiveGenerator<Output>,
        context: TuningContext,
        insideSubdividedChooseBits: Bool,
        predicate: @escaping (Output) -> Bool
    ) throws -> ReflectiveGenerator<Output> {
        switch gen {
        case .pure:
            return gen

        case let .impure(op, continuation):
            switch op {
            case let .pick(choices):
                return try measureAndTunePick(
                    choices: choices,
                    continuation: continuation,
                    context: context,
                    insideSubdividedChooseBits: insideSubdividedChooseBits,
                    predicate: predicate
                )

            case let .chooseBits(lower, upper, tag, isRangeExplicit):
                if insideSubdividedChooseBits {
                    return gen
                }
                return try tuneChooseBits(
                    lower: lower,
                    upper: upper,
                    tag: tag,
                    isRangeExplicit: isRangeExplicit,
                    continuation: continuation,
                    context: context,
                    predicate: predicate
                )

            case let .sequence(lengthGen, elementGen):
                return try tuneSequence(
                    lengthGen: lengthGen,
                    elementGen: elementGen,
                    continuation: continuation,
                    context: context,
                    insideSubdividedChooseBits: insideSubdividedChooseBits,
                    predicate: predicate
                )

            case .getSize:
                return try tuneGetSize(
                    continuation: continuation,
                    context: context,
                    predicate: predicate
                )

            case let .zip(generators, _):
                return try tuneZip(
                    generators: generators,
                    continuation: continuation,
                    context: context,
                    predicate: predicate
                )

            case let .filter(subGen, fingerprint, filterType, filterPredicate):
                return try tuneFilter(
                    subGen: subGen,
                    fingerprint: fingerprint,
                    filterType: filterType,
                    filterPredicate: filterPredicate,
                    continuation: continuation,
                    context: context
                )

            case let .contramap(transform, next):
                return try tuneContramap(
                    transform: transform,
                    next: next,
                    continuation: continuation,
                    context: context,
                    predicate: predicate
                )

            case let .resize(newSize, next):
                return try tuneResize(
                    newSize: newSize,
                    next: next,
                    continuation: continuation,
                    context: context,
                    insideSubdividedChooseBits: insideSubdividedChooseBits,
                    predicate: predicate
                )

            case let .unique(subGen, fingerprint, keyExtractor):
                let tunedInner = try tuneRecursive(
                    subGen,
                    context: context,
                    insideSubdividedChooseBits: insideSubdividedChooseBits,
                    predicate: { _ in true }
                )
                return .impure(
                    operation: .unique(
                        gen: tunedInner,
                        fingerprint: fingerprint,
                        keyExtractor: keyExtractor
                    ),
                    continuation: continuation
                )

            case let .transform(kind, inner):
                let tunedInner = try tuneRecursive(
                    inner,
                    context: context,
                    insideSubdividedChooseBits: insideSubdividedChooseBits,
                    predicate: { _ in true }
                )
                return .impure(
                    operation: .transform(kind: kind, inner: tunedInner),
                    continuation: continuation
                )

            case .just, .prune, .classify:
                return gen
            }
        }
    }

    // MARK: - Weight Smoothing

    /// Applies Laplace smoothing and temperature scaling to pick weights in a tuned generator.
    ///
    // MARK: - Adaptive Smoothing

    /// Applies per-site temperature scaling based on entropy analysis.
    ///
    /// Forwards to ``AdaptiveSmoothing/smooth(_:epsilon:baseTemperature:maxTemperature:)``.
    public static func smoothAdaptively<Output>(
        _ generator: ReflectiveGenerator<Output>,
        epsilon: Double = 1.0,
        baseTemperature: Double = 1.0,
        maxTemperature: Double = 4.0
    ) -> ReflectiveGenerator<Output> {
        AdaptiveSmoothing.smooth(
            generator,
            epsilon: epsilon,
            baseTemperature: baseTemperature,
            maxTemperature: maxTemperature
        )
    }
}
