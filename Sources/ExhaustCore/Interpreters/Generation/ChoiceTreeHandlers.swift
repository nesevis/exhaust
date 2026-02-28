//
//  ChoiceTreeHandlers.swift
//  Exhaust
//
//  Created by Chris Kolbu on 28/2/2026.
//

enum ChoiceTreeHandlers {
    /// Resolves the generator to use for a filter operation, using the tuning cache.
    @inline(__always)
    static func resolveFilterGenerator(
        gen: ReflectiveGenerator<Any>,
        fingerprint: UInt64,
        filterType: FilterType,
        predicate: @escaping (Any) -> Bool,
        context: inout GenerationContext,
    ) -> ReflectiveGenerator<Any> {
        if filterType == .reject {
            return gen
        }
        if let cached = context.tunedFilterCache[fingerprint] {
            return cached
        }
        let tuned = try? GeneratorTuning.probeAndTune(gen, predicate: predicate)
        let resolved = tuned ?? gen
        context.tunedFilterCache[fingerprint] = resolved
        return resolved
    }

    /// Checks whether a generated result is a duplicate for a unique combinator.
    /// Returns `true` if duplicate.
    @inline(__always)
    static func checkDuplicate(
        result: Any,
        tree: ChoiceTree,
        fingerprint: UInt64,
        keyExtractor: ((Any) -> AnyHashable)?,
        context: inout GenerationContext,
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
