/// Tracks inputs that can influence a materialized value or its active structure, including discarded attempts. Generator definitions and fixed decoding settings are implicit; advancing the PRNG without using its output does not add a dependency.
///
/// Only `.prefix` alone certifies a guided property pass for reuse across incumbents. An empty set records no observed inputs and deliberately does not certify cross-incumbent reuse; `.unknown` means dependencies were not fully established.
package struct MaterializationSources: OptionSet, Sendable {
    package let rawValue: UInt8

    package init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// Values, branch selectors, or structural boundaries read from the candidate sequence.
    package static let prefix = Self(rawValue: 1 << 0)
    /// Values or structural boundaries supplied by the incumbent's tree.
    package static let fallbackTree = Self(rawValue: 1 << 1)
    /// Random draws used to resolve a value or select a branch.
    package static let prng = Self(rawValue: 1 << 2)
    /// Depth selected by screening policy instead of the candidate sequence.
    package static let screeningPolicy = Self(rawValue: 1 << 3)
    /// Unobserved or conservatively retained dependencies, including auditions and retries.
    package static let unknown = Self(rawValue: 1 << 4)
}

// MARK: - Diagnostics

extension MaterializationSources: CustomStringConvertible {
    package var description: String {
        let names: [(source: Self, name: String)] = [
            (.prefix, "prefix"),
            (.fallbackTree, "fallbackTree"),
            (.prng, "prng"),
            (.screeningPolicy, "screeningPolicy"),
            (.unknown, "unknown"),
        ]
        return "[" + names.filter { contains($0.source) }.map(\.name).joined(separator: ", ") + "]"
    }
}
