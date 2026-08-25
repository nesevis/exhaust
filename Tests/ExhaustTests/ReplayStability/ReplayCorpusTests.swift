import Exhaust
import ExhaustCore
import ExhaustTestSupport
import Foundation
import Testing

/// Pins the exact values every public entry point produces for fixed seeds.
///
/// Replay stability is part of the 1.0 contract: a seed must reproduce the same values across minor and patch releases, and breaking that requires a major version bump. This suite makes the promise mechanical. Each ``ReplayCorpusEntry`` renders the stream a seed produces through a public macro, and `ReplayCorpus.jsonl` beside this file holds the recorded renderings. Any drift fails with the entry, seed, and first differing index.
///
/// To re-record after a deliberate, major-version replay change, run with `EXHAUST_RECORD_REPLAY_CORPUS=1`; the diff of the corpus file then shows exactly which streams moved. Never re-record to make a failing run pass in a minor release.
@Suite("Replay stability corpus", .serialized)
struct ReplayCorpusTests {
    @Test("Recorded values reproduce", .enabled(if: ReplayCorpus.isRecording == false), arguments: ReplayCorpusEntry.all)
    func recordedValuesReproduce(entry: ReplayCorpusEntry) async throws {
        let corpus = try ReplayCorpus.load()
        for seed in ReplayCorpusEntry.seeds {
            let actual = await entry.capture(seed)
            guard let expected = corpus.values[ReplayCorpus.Key(entry: entry.name, seed: seed)] else {
                Issue.record("\(entry.name) has no recorded values for seed \(seed). Record the corpus with EXHAUST_RECORD_REPLAY_CORPUS=1 and commit the file.")
                continue
            }
            #expect(actual == expected, Comment(rawValue: ReplayCorpus.driftMessage(entry: entry.name, seed: seed, expected: expected, actual: actual)))
        }
    }

    @Test("Capture is deterministic within a process", arguments: ReplayCorpusEntry.all)
    func captureIsDeterministic(entry: ReplayCorpusEntry) async {
        for seed in ReplayCorpusEntry.seeds {
            let first = await entry.capture(seed)
            let second = await entry.capture(seed)
            #expect(first == second, "\(entry.name) rendered differently across two captures under seed \(seed); the corpus cannot pin a nondeterministic stream")
        }
    }

    @Test("Corpus holds no orphaned lines", .enabled(if: ReplayCorpus.isRecording == false))
    func corpusHoldsNoOrphanedLines() throws {
        let corpus = try ReplayCorpus.load()
        let known = Set(ReplayCorpusEntry.all.map(\.name)).union(ReplayCorpusEntry.platformGated)
        let orphans = corpus.values.keys.map(\.entry).filter { known.contains($0) == false }
        #expect(orphans.isEmpty, "Corpus lines without a matching entry: \(Set(orphans).sorted()). Re-record to drop them.")
    }

    @Test("Record corpus", .enabled(if: ReplayCorpus.isRecording))
    func recordCorpus() async throws {
        var lines: [ReplayCorpus.Line] = []
        for entry in ReplayCorpusEntry.all {
            for seed in ReplayCorpusEntry.seeds {
                await lines.append(ReplayCorpus.Line(entry: entry.name, seed: seed, values: entry.capture(seed)))
            }
        }
        try ReplayCorpus.write(lines)
    }
}

// MARK: - Corpus File

/// The recorded corpus: one JSON line per entry and seed, kept beside the test source so record mode can rewrite it in place.
enum ReplayCorpus {
    struct Key: Hashable {
        let entry: String
        let seed: UInt64
    }

    struct Line: Codable {
        let entry: String
        let seed: UInt64
        let values: [String]
    }

    struct Loaded {
        let values: [Key: [String]]
    }

    static var isRecording: Bool {
        ProcessInfo.processInfo.environment["EXHAUST_RECORD_REPLAY_CORPUS"] != nil
    }

    static var fileURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("ReplayCorpus.jsonl")
    }

    static func load() throws -> Loaded {
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        let decoder = JSONDecoder()
        var values: [Key: [String]] = [:]
        for rawLine in text.split(separator: "\n") where rawLine.isEmpty == false {
            let line = try decoder.decode(Line.self, from: Data(rawLine.utf8))
            values[Key(entry: line.entry, seed: line.seed)] = line.values
        }
        return Loaded(values: values)
    }

    /// Writes the corpus sorted by entry then seed, one compact JSON object per line, so re-recording produces minimal diffs.
    static func write(_ lines: [Line]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let sorted = lines.sorted { lhs, rhs in
            lhs.entry == rhs.entry ? lhs.seed < rhs.seed : lhs.entry < rhs.entry
        }
        var text = ""
        for line in sorted {
            let data = try encoder.encode(line)
            guard let encoded = String(bytes: data, encoding: .utf8) else {
                throw CorpusError.lineNotUTF8(line.entry)
            }
            text += encoded + "\n"
        }
        try text.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    enum CorpusError: Error {
        case lineNotUTF8(String)
    }

    static func driftMessage(entry: String, seed: UInt64, expected: [String], actual: [String]) -> String {
        let pairs = Array(zip(expected, actual))
        let location = switch pairs.firstIndex(where: { $0.0 != $0.1 }) {
            case let .some(index):
                "index \(index): expected \(pairs[index].0), got \(pairs[index].1)"
            case .none:
                "length \(expected.count) recorded, \(actual.count) produced"
        }
        return "Replay stability broken for \(entry) under seed \(seed) (\(location)). A seed no longer reproduces its recorded values: this is a MAJOR version change. Re-record only alongside a major bump."
    }
}
