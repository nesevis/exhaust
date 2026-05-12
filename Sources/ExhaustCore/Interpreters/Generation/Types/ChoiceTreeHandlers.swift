//
//  ChoiceTreeHandlers.swift
//  Exhaust
//
//  Created by Chris Kolbu on 28/2/2026.
//

/// Provides choice-tree-building callbacks that the generation interpreter passes to operation handlers.
package enum ChoiceTreeHandlers {
    /// Checks whether a generated result is a duplicate for a unique combinator.
    /// Returns `true` if duplicate.
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
