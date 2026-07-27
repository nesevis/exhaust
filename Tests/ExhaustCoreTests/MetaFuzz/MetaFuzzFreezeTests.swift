import ExhaustCore
import ExhaustTestSupport
import Foundation
import Testing

/// Guards the finding recorder's cap and dedupe semantics. The recorder keeps an in-process name set so a repeat finding costs a set lookup, but the cap must bound the findings directory, not the process: the set seeds from one disk listing per directory, so repeated harness runs against the same directory cannot accumulate past ``MetaFuzz/findingsPerOracleCap``.
@Suite("MetaFuzz finding recorder")
struct MetaFuzzFreezeTests {
    @Test("A first finding writes one file and a repeat of it writes nothing")
    func repeatFindingIsRecordedOnce() throws {
        let directory = try makeFindingsDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let fuzzCase = makeFuzzCase(valueSeed: 1)

        let firstURL = MetaFuzz.recordFinding(fuzzCase, violation: ProbeOracleViolation(), in: directory)
        let repeatURL = MetaFuzz.recordFinding(fuzzCase, violation: ProbeOracleViolation(), in: directory)

        #expect(firstURL != nil)
        #expect(repeatURL == nil)
        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(contents.count == 1)
    }

    @Test("The per-oracle cap counts files already on disk from earlier runs")
    func capCountsFilesFromEarlierRuns() throws {
        let directory = try makeFindingsDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        // An earlier run's findings are files on disk with no trace in this process's memory. Seeding the directory before the first call stands in for that run.
        for index in 0 ..< MetaFuzz.findingsPerOracleCap {
            let file = directory.appendingPathComponent("ProbeOracleViolation-earlier\(index).json")
            try Data("{}".utf8).write(to: file)
        }

        let recordedURL = MetaFuzz.recordFinding(makeFuzzCase(valueSeed: 2), violation: ProbeOracleViolation(), in: directory)

        #expect(recordedURL == nil, "A directory already holding the cap for this oracle must not grow")
        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(contents.count == MetaFuzz.findingsPerOracleCap)
    }

    @Test("The cap applies per oracle, so a different oracle still records into a full directory")
    func capIsPerOracle() throws {
        let directory = try makeFindingsDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        for index in 0 ..< MetaFuzz.findingsPerOracleCap {
            let file = directory.appendingPathComponent("ProbeOracleViolation-earlier\(index).json")
            try Data("{}".utf8).write(to: file)
        }

        let recordedURL = MetaFuzz.recordFinding(makeFuzzCase(valueSeed: 3), violation: OtherProbeOracleViolation(), in: directory)

        #expect(recordedURL != nil, "The cap bounds each oracle's findings, not the directory as a whole")
    }

    @Test("A re-seeded cache still honours a cap the process itself filled")
    func capSurvivesCacheReset() throws {
        let directory = try makeFindingsDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        for index in 0 ..< MetaFuzz.findingsPerOracleCap {
            MetaFuzz.recordFinding(makeFuzzCase(valueSeed: UInt64(index)), violation: ProbeOracleViolation(), in: directory)
        }
        // Stands in for a second harness run against the same directory: the names cache is gone, the files are not.
        MetaFuzz.forgetRecordedFindings()

        let recordedURL = MetaFuzz.recordFinding(makeFuzzCase(valueSeed: 999), violation: ProbeOracleViolation(), in: directory)

        #expect(recordedURL == nil, "Re-seeding from disk must carry the cap across a process boundary")
        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(contents.count == MetaFuzz.findingsPerOracleCap)
    }

    @Test("Directories are tracked independently")
    func directoriesAreTrackedIndependently() throws {
        let firstDirectory = try makeFindingsDirectory()
        let secondDirectory = try makeFindingsDirectory()
        defer {
            try? FileManager.default.removeItem(at: firstDirectory)
            try? FileManager.default.removeItem(at: secondDirectory)
        }
        let fuzzCase = makeFuzzCase(valueSeed: 4)

        let firstURL = MetaFuzz.recordFinding(fuzzCase, violation: ProbeOracleViolation(), in: firstDirectory)
        let secondURL = MetaFuzz.recordFinding(fuzzCase, violation: ProbeOracleViolation(), in: secondDirectory)

        #expect(firstURL != nil)
        #expect(secondURL != nil, "A finding recorded in one directory must not claim the name in another")
    }
}

// MARK: - Helpers

/// Files are the shared resource here, so every test writes into its own directory. The name cache is keyed by that path, which isolates it too.
private func makeFindingsDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MetaFuzzFreezeTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

/// The recorder only reads the case's description (for the filename hash) and its codable fields (for the frozen record), so the smallest well-formed recipe serves.
private func makeFuzzCase(valueSeed: UInt64) -> MetaFuzzCase {
    MetaFuzzCase(recipe: .leaf(.justInt(7)), valueSeed: valueSeed, perturbationSeed: 0)
}

private struct ProbeOracleViolation: Error {}

private struct OtherProbeOracleViolation: Error {}
