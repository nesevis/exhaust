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

        let resolved: ReflectiveGenerator<Any>
        let effectiveType = filterType == .auto && context.maxRuns < 200 && !containsSequence(gen)
            ? FilterType.choiceGradient
            : filterType

        switch effectiveType {
        case .reject:
            return gen
        case .choiceGradient:
            let tuned = try? OnlineCGSInterpreter<Any>.tune(gen, predicate: predicate, warmupRuns: context.maxRuns)
            resolved = tuned ?? gen
        case .tune, .auto:
            let tuned = try? GeneratorTuning.probeAndTune(gen, predicate: predicate)
            resolved = tuned ?? gen
        }

        context.tunedFilterCache[fingerprint] = resolved
        return resolved
    }

    /// Returns `true` if the generator tree contains a `.sequence` operation.
    private static func containsSequence(_ gen: ReflectiveGenerator<some Any>) -> Bool {
        switch gen {
        case .pure:
            return false
        case let .impure(operation, _):
            switch operation {
            case .sequence:
                return true
            case let .pick(choices):
                return choices.contains { containsSequence($0.generator) }
            case let .zip(generators):
                return generators.contains { containsSequence($0) }
            case let .filter(subGen, _, _, _):
                return containsSequence(subGen)
            case let .classify(subGen, _, _):
                return containsSequence(subGen)
            case let .unique(subGen, _, _):
                return containsSequence(subGen)
            case let .contramap(_, next):
                return containsSequence(next)
            case let .prune(next):
                return containsSequence(next)
            case let .resize(_, next):
                return containsSequence(next)
            case .chooseBits, .just, .getSize:
                return false
            }
        }
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
