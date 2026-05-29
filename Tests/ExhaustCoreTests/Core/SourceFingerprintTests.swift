//
//  SourceFingerprintTests.swift
//  Exhaust
//

import ExhaustCore
import Testing

@Suite("Source fingerprint")
struct SourceFingerprintTests {
    @Test("Identical source-location inputs yield identical fingerprints")
    func deterministicForSameInputs() {
        let first = Gen.sourceFingerprint(fileID: "ExhaustCore/Sample.swift", line: 42, column: 7)
        let second = Gen.sourceFingerprint(fileID: "ExhaustCore/Sample.swift", line: 42, column: 7)
        #expect(first == second)
    }

    @Test("Transposed line and column do not collide")
    func transposedLineColumnDoNotCollide() {
        let lineThenColumn = Gen.sourceFingerprint(fileID: "ExhaustCore/Sample.swift", line: 10, column: 5)
        let columnThenLine = Gen.sourceFingerprint(fileID: "ExhaustCore/Sample.swift", line: 5, column: 10)
        #expect(lineThenColumn != columnThenLine)
    }

    @Test("Each source-location component changes the fingerprint")
    func componentsAreDistinguished() {
        let base = Gen.sourceFingerprint(fileID: "ExhaustCore/Sample.swift", line: 10, column: 5)
        #expect(Gen.sourceFingerprint(fileID: "ExhaustCore/Sample.swift", line: 11, column: 5) != base)
        #expect(Gen.sourceFingerprint(fileID: "ExhaustCore/Sample.swift", line: 10, column: 6) != base)
        #expect(Gen.sourceFingerprint(fileID: "ExhaustCore/Other.swift", line: 10, column: 5) != base)
    }

    @Test("Transposed file-identifier characters do not collide")
    func transposedFileCharactersDoNotCollide() {
        // A positional byte fold distinguishes anagram-like identifiers that a commutative byte sum would conflate.
        let forwardOrder = Gen.sourceFingerprint(fileID: "ab", line: 1, column: 1)
        let reverseOrder = Gen.sourceFingerprint(fileID: "ba", line: 1, column: 1)
        #expect(forwardOrder != reverseOrder)
    }

    @Test("Fingerprint is pinned to a known value, guarding against per-process hashing")
    func pinnedGoldenValue() {
        // The golden value is a pure function of the inputs. If the mixing algorithm changes deliberately, update it; if it ever depends on a per-process hash (for example String.hashValue), this assertion fails because the value would differ across runs.
        let fingerprint = Gen.sourceFingerprint(fileID: "ExhaustCore/Golden.swift", line: 123, column: 45)
        #expect(fingerprint == 0x0830_EA39_FF7F_4ABF)
    }
}
