//
//  ChoiceTreeHandlers.swift
//  Exhaust
//
//  Created by Chris Kolbu on 28/2/2026.
//

public enum ChoiceTreeHandlers {
    /// Resolves the generator to use for a filter operation, using the tuning cache.
    @inline(__always)
    public static func resolveFilterGenerator(
        gen: ReflectiveGenerator<Any>,
        fingerprint: UInt64,
        filterType: FilterType,
        predicate: @escaping (Any) -> Bool,
        context: inout GenerationContext
    ) -> ReflectiveGenerator<Any> {
        if filterType == .rejectionSampling {
            return gen
        }
        if let cached = context.tunedFilterCache[fingerprint] {
            return cached
        }

        let resolved: ReflectiveGenerator<Any>

        switch filterType {
        case .rejectionSampling:
            return gen
        case .choiceGradientSampling, .auto:
            // CGS with fitness sharing is faster than probe-tuning at all run
            // counts for pick-heavy generators (3x on AVL, 2x on BST).
            let tuned = try? ChoiceGradientTuner<Any>.tune(
              gen,
              predicate: predicate,
              warmupRuns: context.maxRuns,
              seed: context.baseSeed
            )
            resolved = tuned ?? gen
        case .probeSampling:
            let tuned = try? GeneratorTuning.probeAndTune(gen, seed: context.baseSeed, predicate: predicate)
            resolved = tuned ?? gen
        }

        context.tunedFilterCache[fingerprint] = resolved
        return resolved
    }

    /// Checks whether a generated result is a duplicate for a unique combinator.
    /// Returns `true` if duplicate.
    @inline(__always)
    public static func checkDuplicate(
        result: Any,
        tree: ChoiceTree,
        fingerprint: UInt64,
        keyExtractor: ((Any) -> AnyHashable)?,
        context: inout GenerationContext
    ) -> Bool {
        if let keyExtractor {
            let key = keyExtractor(result)
            return !context.uniqueSeenKeys[fingerprint, default: []].insert(key).inserted
        } else {
            let sequence = ChoiceSequence.flatten(tree)
            return !context.uniqueSeenSequences[fingerprint, default: []].insert(sequence).inserted
        }
    }
}
