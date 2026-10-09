//
//  CharacterSimplifications.swift
//  Exhaust
//

import Foundation

// MARK: - Character Simplifications

/// Maps character indices in a ``ScalarRangeSet`` to the indices of simpler forms of the same character, such as `å` to `A`, `Å`, and `a`.
///
/// Binary search over character indices cannot reach these forms: an uppercase letter sits 32 indices below its lowercase form in ASCII, and an accented letter sits further still from its base, while the property usually fails only at those exact characters. The value encoder proposes these indices directly once binary search on a character leaf converges.
///
/// Candidates come from the transitive closure of case mapping (upper, lower, and case-insensitive folding) and decomposition (NFD and NFKD), taking each scalar of every transformed form. Combining marks are dropped: decomposition separates them from their base letter, and they often sit below the precomposed letter in index order, but replacing a letter with a bare mark is never a useful proposal. Each source keeps only candidates that are members of the range set and have a strictly lower index, sorted ascending so the first accepted candidate is the simplest reachable one.
///
/// The UTF-8 width minimums U+0080, U+0800, and U+10000 also have the minimums of every shorter width as explicit simplifications. These entries use the same domain and index filtering as case/decomposition forms.
///
/// Sources cover the blocks where counterexample text plausibly lands: Latin, IPA, Greek, and Cyrillic; Latin Extended Additional and Greek Extended; Latin ligatures; fullwidth forms; and mathematical alphanumerics. CJK compatibility forms and the remaining scripts hold most of Unicode's simplifiable scalars but are left out to keep the table at a few thousand entries.
@usableFromInline
package struct CharacterSimplifications: Sendable {
    /// Source indices with at least one candidate, sorted ascending.
    private let sources: [UInt64]

    /// `candidateOffsets[i] ..< candidateOffsets[i + 1]` addresses the candidates for `sources[i]` in ``candidates``.
    private let candidateOffsets: [Int]

    /// Candidate indices for every source, concatenated. Each source's run is sorted ascending.
    private let candidates: [UInt64]

    /// A table with no entries, for payloads whose leaves should never be simplified.
    @usableFromInline
    package static let empty = CharacterSimplifications(sources: [], candidateOffsets: [0], candidates: [])

    private init(sources: [UInt64], candidateOffsets: [Int], candidates: [UInt64]) {
        self.sources = sources
        self.candidateOffsets = candidateOffsets
        self.candidates = candidates
    }

    /// Builds the table for a range set by mapping the shared scalar closure into the set's index space.
    init(
        contains: (Unicode.Scalar) -> Bool,
        index: (Unicode.Scalar) -> Int
    ) {
        var sources: [UInt64] = []
        var candidateOffsets = [0]
        var candidates: [UInt64] = []
        for (source, forms) in Self.simplerForms where contains(source) {
            let sourceIndex = UInt64(index(source))
            let simpler = Set(forms.lazy.filter(contains).map { UInt64(index($0)) })
                .filter { $0 < sourceIndex }
                .sorted()
            guard simpler.isEmpty == false else {
                continue
            }
            sources.append(sourceIndex)
            candidates += simpler
            candidateOffsets.append(candidates.count)
        }
        self.sources = sources
        self.candidateOffsets = candidateOffsets
        self.candidates = candidates
    }

    /// Returns the simpler indices for `index`, ascending, or an empty slice when the index has none.
    package func simplerIndices(than index: UInt64) -> ArraySlice<UInt64> {
        var low = 0
        var high = sources.count
        while low < high {
            let middle = low + (high - low) / 2
            if sources[middle] < index {
                low = middle + 1
            } else {
                high = middle
            }
        }
        guard low < sources.count,
              sources[low] == index
        else {
            return []
        }
        return candidates[candidateOffsets[low] ..< candidateOffsets[low + 1]]
    }

    // MARK: - Scalar Closure

    /// Source scalar ranges covered by the table, ascending and disjoint so that sources come out in index order.
    private static let coveredRanges: [ClosedRange<UInt32>] = [
        0x0000 ... 0x052F, // Latin, IPA, Greek, and Cyrillic
        0x0800 ... 0x0800, // Three-byte UTF-8 minimum
        0x1E00 ... 0x1FFF, // Latin Extended Additional and Greek Extended
        0xFB00 ... 0xFB06, // Latin ligatures
        0xFF00 ... 0xFFEF, // Fullwidth and halfwidth forms
        0x10000 ... 0x10000, // Four-byte UTF-8 minimum
        0x1D400 ... 0x1D7FF, // Mathematical alphanumerics
    ]

    /// Every source scalar in ``coveredRanges``, sorted, paired with its case/decomposition forms or explicit width-minimum simplifications. Computed once and shared by every range set.
    private static let simplerForms: [(Unicode.Scalar, [Unicode.Scalar])] = {
        var table: [(Unicode.Scalar, [Unicode.Scalar])] = []
        let widthMinimums: [UInt32] = [0, 0x80, 0x800, 0x10000]
        for value in coveredRanges.joined() {
            guard let source = Unicode.Scalar(value) else {
                continue
            }
            var reached: Set<Unicode.Scalar> = [source]
            var frontier: [Unicode.Scalar] = [source]
            while let scalar = frontier.popLast() {
                for form in transformedForms(of: scalar) {
                    for next in form.unicodeScalars where reached.insert(next).inserted {
                        frontier.append(next)
                    }
                }
            }
            if let width = widthMinimums.firstIndex(of: value) {
                reached.formUnion(widthMinimums.prefix(width).map { Unicode.Scalar($0)! })
            }
            reached.remove(source)
            let candidates = reached.filter { isCombiningMark($0) == false }
            guard candidates.isEmpty == false else {
                continue
            }
            table.append((source, candidates.sorted { $0.value < $1.value }))
        }
        return table
    }()

    private static func isCombiningMark(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark:
                true
            default:
                false
        }
    }

    private static func transformedForms(of scalar: Unicode.Scalar) -> [String] {
        let text = String(scalar)
        return [
            text.uppercased(),
            text.lowercased(),
            text.folding(options: .caseInsensitive, locale: nil),
            text.decomposedStringWithCanonicalMapping,
            text.decomposedStringWithCompatibilityMapping,
        ]
    }
}

// MARK: - Hashable

/// Every node built by one generator shares the same table, so equality usually short-circuits on array buffer identity. Hashing only the counts keeps payload hashing independent of table size; equal tables still hash equally.
extension CharacterSimplifications: Hashable {
    @usableFromInline
    package func hash(into hasher: inout Hasher) {
        hasher.combine(sources.count)
        hasher.combine(candidates.count)
    }
}
