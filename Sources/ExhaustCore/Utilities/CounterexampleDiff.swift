//
//  CounterexampleDiff.swift
//  Exhaust
//
//  Created by Chris Kolbu on 23/2/2026.
//

package enum CounterexampleDiff {
    /// Formats a human-readable diff between an original failing value and its shrunk counterpart.
    ///
    /// For structs/classes with labeled children, produces a property-level diff showing only
    /// changed fields with dotted paths for nested structs. Falls back to showing both values
    /// on separate lines for unlabeled or mismatched types.
    package static func format<Output>(
        original: Output,
        shrunk: Output,
    ) -> String {
        var lines: [String] = []
        let correlated = correlatedDiff(
            original: original,
            shrunk: shrunk,
            prefix: "",
            depth: 0,
            lines: &lines,
        )

        if correlated {
            if lines.isEmpty {
                return "Counterexample diff (shrunk \u{2190} original):\n  (no visible change)"
            }
            return "Counterexample diff (shrunk \u{2190} original):\n" + lines.joined(separator: "\n")
        } else {
            let shrunkDesc = String(describing: shrunk)
            let originalDesc = String(describing: original)

            switch (shrunkDesc.count, originalDesc.count) {
            case (0 ... 20, 0 ... 30):
                return "Counterexample \(shrunkDesc) \u{2190} \(originalDesc)"
            case (21 ... 40, _):
                return "Counterexample \(shrunkDesc) \u{2190} \(originalDesc.prefix(30))…"
            default:
                return "Counterexample diff (shrunk \u{2190} original):\n"
            }

            return "Counterexample diff (shrunk \u{2190} original):\n"
                + "  shrunk:   \(String(describing: shrunk))\n"
                + "  original: \(String(describing: original))"
        }
    }

    // MARK: - Private

    private static let maxDepth = 3

    /// Attempts a correlated, property-level diff using `Mirror`.
    /// Returns `true` if a correlated diff was possible, `false` if fallback is needed.
    private static func correlatedDiff<Value>(
        original: Value,
        shrunk: Value,
        prefix: String,
        depth: Int,
        lines: inout [String],
    ) -> Bool {
        let originalMirror = Mirror(reflecting: original)
        let shrunkMirror = Mirror(reflecting: shrunk)

        guard isLabeledStructural(originalMirror),
              isLabeledStructural(shrunkMirror),
              originalMirror.children.count == shrunkMirror.children.count,
              !originalMirror.children.isEmpty
        else {
            return false
        }

        for (originalChild, shrunkChild) in zip(originalMirror.children, shrunkMirror.children) {
            guard let label = originalChild.label else { return false }

            let key = prefix.isEmpty ? label : "\(prefix).\(label)"
            let originalDesc = String(describing: originalChild.value)
            let shrunkDesc = String(describing: shrunkChild.value)

            if originalDesc == shrunkDesc { continue }

            let childOriginalMirror = Mirror(reflecting: originalChild.value)
            if depth < maxDepth,
               isLabeledStructural(childOriginalMirror),
               isLabeledStructural(Mirror(reflecting: shrunkChild.value)),
               !childOriginalMirror.children.isEmpty
            {
                let childCorrelated = correlatedDiff(
                    original: originalChild.value,
                    shrunk: shrunkChild.value,
                    prefix: key,
                    depth: depth + 1,
                    lines: &lines,
                )
                if !childCorrelated {
                    lines.append("  \(key): \(shrunkDesc) \u{2190} \(originalDesc)")
                }
            } else {
                lines.append("  \(key): \(shrunkDesc) \u{2190} \(originalDesc)")
            }
        }

        return true
    }

    private static func isLabeledStructural(_ mirror: Mirror) -> Bool {
        switch mirror.displayStyle {
        case .struct, .class:
            mirror.children.allSatisfy { $0.label != nil }
        default:
            false
        }
    }
}
