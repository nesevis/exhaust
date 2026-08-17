import Testing
@testable import ExhaustCore

@Suite("Unicode 17 scalar ranges")
struct Unicode17ScalarRangeTests {
    /// Ascending and non-overlapping, so the flat index is a bijection onto the scalars. Reflection round-trips depend on it.
    ///
    /// Adjacent ranges are allowed. Basic Latin and Latin-1 touch, and are written separately so each keeps the reason it is in the list.
    @Test("Ranges are ordered and disjoint")
    func rangesAreOrderedAndDisjoint() {
        var previousUpper: UInt32?
        for range in unicode17ScalarRanges {
            #expect(range.lowerBound <= range.upperBound)
            if let previousUpper {
                #expect(range.lowerBound > previousUpper)
            }
            previousUpper = range.upperBound
        }
    }

    /// Surrogates are not `Unicode.Scalar`s, and noncharacters never appear in interchange. A range spanning either would trap or generate values no caller can receive.
    @Test("Ranges exclude surrogates and noncharacters")
    func rangesExcludeUnrepresentableScalars() {
        for range in unicode17ScalarRanges {
            for codePoint in range {
                #expect(Unicode.Scalar(codePoint) != nil, "U+\(String(codePoint, radix: 16)) is a surrogate")
                let isNoncharacter = (0xFDD0 ... 0xFDEF).contains(codePoint) || (codePoint & 0xFFFE) == 0xFFFE
                #expect(isNoncharacter == false, "U+\(String(codePoint, radix: 16)) is a noncharacter")
            }
        }
    }

    /// The hazards the ranges exist to reach. Each has broken string handling in the wild.
    @Test("Every hazard class is reachable", arguments: [
        (UInt32(0x0000), "NUL, truncates a C string"),
        (UInt32(0x005C), "backslash, escapes"),
        (UInt32(0x0300), "combining grave, no base once reduced"),
        (UInt32(0x200D), "zero-width joiner"),
        (UInt32(0x202E), "right-to-left override"),
        (UInt32(0xFE0F), "variation selector 16"),
        (UInt32(0xFEFF), "byte order mark"),
        (UInt32(0xFFFD), "replacement character"),
        (UInt32(0x1F600), "emoji, two UTF-16 units"),
        (UInt32(0x20000), "CJK Extension B, two UTF-16 units"),
    ])
    func hazardIsReachable(codePoint: UInt32, hazard: String) {
        #expect(unicode17ScalarRanges.contains { $0.contains(codePoint) }, "unreachable: \(hazard)")
    }

    /// Unassigned code points inside the blocks are the headroom that keeps a Unicode release from moving any index. Losing them would mean the domain had been pinned to one version after all.
    @Test("The blocks carry headroom for later Unicode versions")
    func rangesCarryHeadroom() {
        let unassigned = unicode17ScalarRanges
            .flatMap(\.self)
            .filter { Unicode.Scalar($0)?.properties.generalCategory == .unassigned }
        #expect(unassigned.isEmpty == false)
    }

    /// Every scalar the covering-array sampler screens has to be drawable, or screening silently loses that hazard.
    ///
    /// An earlier version of this list was a hand-picked subset of the blocks and dropped three: final sigma, the Kelvin sign, and U+FDFA. Nothing failed, because a boundary value outside the range set is quietly discarded during construction.
    @Test("Every screened boundary scalar is drawable")
    func screenedBoundariesAreDrawable() {
        for codePoint in ProblematicValues.interestingCharacterScalars {
            #expect(
                unicode17ScalarRanges.contains { $0.contains(codePoint) },
                "U+\(String(codePoint, radix: 16, uppercase: true)) is screened but cannot be generated"
            )
        }
    }
}

@Suite("Unicode version selection")
struct UnicodeVersionTests {
    /// Every case has to resolve to a range set, or a caller can select a version that generates nothing.
    @Test("Every version exposes ranges", arguments: UnicodeVersion.allCases)
    func versionExposesRanges(version: UnicodeVersion) {
        #expect(version.scalarRanges.isEmpty == false)
        #expect(version.scalarRangeSet.scalarCount > 0)
    }

    /// The default is what an unadorned `.character()` or `.string()` draws from. Changing it is a breaking change to every recorded replay seed, so it is pinned here rather than left implicit.
    @Test("The default version is 17")
    func defaultVersionIsSeventeen() {
        #expect(UnicodeVersion.v17.scalarRanges.count == unicode17ScalarRanges.count)
    }
}
