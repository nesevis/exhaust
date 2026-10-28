import ExhaustCore
import Foundation
import Testing
@testable import Exhaust

@Suite("Campaign attachment names")
struct FuzzAttachmentTests {
    @Test("Parallel cases record summaries and clusters with their own seed", arguments: [UInt64(1), 2])
    func campaignReports(seed: UInt64) {
        let report = FuzzCampaignFixture.failingReport(seed: seed)
        #expect(report.seed == seed)
        #expect(report.clusters.isEmpty == false)
        let context = FuzzCampaignContext.resolve(
            fileID: #fileID,
            filePath: #filePath,
            line: #line,
            column: #column,
            seed: seed,
            kind: .value,
            time: .seconds(1)
        )
        let names = __ExhaustRuntime.recordFuzzAttachments(
            report: report,
            context: context,
            suppressAttachments: false,
            campaignID: "campaign-\(seed)"
        )
        let prefix = context.attachmentPrefix(seed: seed, campaignID: "campaign-\(seed)")
        let expected = report.clusters.map { "\(prefix)-cluster-\($0.id + 1).txt" } + ["\(prefix)-summary.txt"]
        #expect(names == expected)
        #expect(names.allSatisfy { $0.contains("FuzzAttachmentTests.campaignReports-seed-\(seed)-campaign-\(seed)") })
        #expect(__ExhaustRuntime.recordFuzzAttachments(report: report, context: context, suppressAttachments: true)
            .isEmpty)
    }

    @Test("Names distinguish tests and seeds and remain safe filename components")
    func filenames() {
        let first = prefix(testName: "Suite.roundTrip", seed: 1)
        #expect(first == "explore-time-Suite.roundTrip-seed-1")
        #expect(first != prefix(testName: "Suite.roundTrip", seed: 2))
        #expect(first != prefix(testName: "Other.roundTrip", seed: 1))
        let unsafe = prefix(testName: "../Suite\\test:/name?", seed: 1)
        #expect(unsafe.contains("/") == false)
        #expect(unsafe.contains("\\") == false)
        #expect(unsafe.contains(":") == false)
        #expect(unsafe.contains("?") == false)
        #expect(prefix(testName: nil, seed: 42) == "explore-time-standalone-seed-42")
    }

    @Test("Long Unicode test names leave room for the seed and cluster suffix")
    func longName() {
        let prefix = prefix(testName: String(repeating: "試験", count: 100), seed: .max)
        #expect(prefix.contains("試験"))
        #expect(prefix.hasSuffix("-seed-18446744073709551615"))
        #expect((prefix + "-cluster-18446744073709551615.txt").utf8.count < 255)
    }

    @Test("Any test name yields a portable attachment filename within the 255-byte name limit")
    func portableNames() {
        // Separators and characters Windows reserves in filenames, plus control characters and newlines.
        let unportable = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters).union(.newlines)
        let gen = #gen(.string(length: 0 ... 200).optional(), .uint64(), .uuid())
        #exhaust(gen) { testName, seed, campaign in
            let campaignID = campaign.uuidString
            let prefix = prefix(testName: testName, seed: seed, campaignID: campaignID)
            // Scalars, not characters: a sanitized name starting with a combining mark joins the preceding hyphen into one character.
            let scalars = Array(prefix.unicodeScalars)
            let head = Array("explore-time-".unicodeScalars)
            let tail = Array("-seed-\(seed)-\(campaignID)".unicodeScalars)
            let name = scalars.dropFirst(head.count).dropLast(tail.count)
            let longestFilename = prefix + "-cluster-\(UInt64.max).txt"
            return scalars.starts(with: head)
                && scalars.reversed().starts(with: tail.reversed())
                && name.isEmpty == false
                && name.allSatisfy { unportable.contains($0) == false }
                && longestFilename.utf8.count <= 255
        }
    }

    @Test("Short alphanumeric Unicode test names appear unchanged in attachment filenames")
    func readableNamesSurvive() {
        // Thirty scalars of at most four UTF-8 bytes each fit within the 120-byte name budget.
        let gen = #gen(.string(from: .alphanumerics, length: 1 ... 30), .uint64())
        #exhaust(gen) { testName, seed in
            let prefix = prefix(testName: testName, seed: seed)
            let expected = "explore-time-" + testName + "-seed-\(seed)"
            return Array(prefix.unicodeScalars) == Array(expected.unicodeScalars)
        }
    }

    private func prefix(testName: String?, seed: UInt64, campaignID: String? = nil) -> String {
        FuzzCampaignContext(
            fileID: "Tests/Test.swift",
            filePath: "/tests/Test.swift",
            line: 1,
            column: 1,
            testID: testName,
            testName: testName,
            seed: seed,
            kind: .value,
            time: .seconds(1),
            environment: [:]
        ).attachmentPrefix(seed: seed, campaignID: campaignID)
    }
}
