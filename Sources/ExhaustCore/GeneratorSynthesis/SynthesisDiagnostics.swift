/// Thrown by ``ExampleDecoder`` when a generated value drives `init(from:)` to decode a key or tape position the discovery pass never recorded.
///
/// A synthesized generator builds its example tape from a single example. A hand-written `init(from:)` that branches on a decoded value can, at generation time, take a branch the example did not exercise and ask for a value that was never generated. Rather than trap on an out-of-range tape read, the example decoder throws this, and the synthesized generator's reconstruction map catches it and pins the affected value to the example (see ``SynthesisDiagnostics/recordFallback(type:codingPath:)``).
package struct GenSchemaMiss: Error {
    /// The coding path of the decode call that found no recorded value.
    package let codingPath: [any CodingKey]

    package init(codingPath: [any CodingKey]) {
        self.codingPath = codingPath
    }
}

/// Reports the catch-and-pin fallbacks a synthesized generator takes at generation time.
package enum SynthesisDiagnostics {
    // MARK: - Deduplication

    /// A unique fallback site: the type whose reconstruction fell back and the coding path of the missed key. `ObjectIdentifier` keys by metatype identity, so two distinct types with the same printed name do not collide into one warning.
    private struct Site: Hashable {
        let type: ObjectIdentifier
        let path: String
    }

    /// A branch the example never covered would otherwise warn once per generated sample; deduplicating by site reduces that to one warning per site. Generation can run on several threads, so the set is held in a `SendableBox` and mutated under its lock. The dedup is process-lifetime — a per-execution reset would require threading the generation context into the reconstruction map.
    private static let warnedSites = SendableBox<Set<Site>>([])

    /// Records a catch-and-pin fallback and emits a deduplicated warning the first time a given `(type, codingPath)` site fires.
    ///
    /// The fallback means a generated value drove `init(from:)` down a branch the example did not cover, so that value was pinned to the example. Visibility follows ``ExhaustLog``'s task-local configuration — the warning is silent when logging is suppressed.
    ///
    /// - Parameters:
    ///   - type: The type whose reconstruction fell back to the example.
    ///   - codingPath: The coding path at which the missing value was requested.
    package static func recordFallback(type: Any.Type, codingPath: [any CodingKey]) {
        let path = codingPath.map(\.stringValue).joined(separator: ".")
        let site = Site(type: ObjectIdentifier(type), path: path)

        // Keep the logging call outside the critical section — only the insert-and-check needs the lock.
        let isFirstFire = warnedSites.withValue { $0.insert(site).inserted }

        guard isFirstFire else { return }

        let location = path.isEmpty ? "the root value" : "\"\(path)\""
        ExhaustLog.warning(
            category: .generation,
            event: "synthesis_branch_fallback",
            "Synthesized generator for \(type) reached a branch the example does not cover at \(location); that sample was pinned to the example value. Provide an example that exercises the branch, or write a generator for this type.",
            metadata: [
                "type": "\(type)",
                "coding_path": path,
            ]
        )
    }
}
