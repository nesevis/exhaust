//
//  MetaFuzzFreeze.swift
//  ExhaustMetaFuzz
//
//  The capture-and-freeze mechanism for self-fuzzing findings: a finding is frozen as a versioned JSON record, committed alongside the fix, and replayed deterministically as a regression gate.
//

import ExhaustCore
import Foundation

/// A frozen reproducer for a self-fuzzing finding.
///
/// One record is one claim: this exact case once violated an oracle and never may again. Records are JSON files in the harness's `Regressions/` directory, decoded and re-run by the replay suite on every PR. The version field gates recipe-language evolution — a record that no longer decodes fails loudly with its provenance rather than silently passing. The kind discriminator exists so block-2 findings (frozen command sequences) share the corpus and replay suite instead of growing a parallel mechanism.
public struct MetaFuzzFrozenCase: Codable, Sendable {
    /// Record kinds the replay suite understands.
    public enum Kind: String, Codable, Sendable {
        /// A block-1 value-pipeline case: recipe plus seeds, replayed through ``MetaFuzz/check(_:)``.
        case pipelineCase
    }

    /// The schema version this record was written with.
    public let version: Int
    /// Which replay path the record takes.
    public let kind: Kind
    /// The violated oracle's error type name, for the record's provenance.
    public let oracle: String
    /// Free-form provenance: what the finding was, where it was fixed.
    public let note: String?
    package let recipe: GenRecipe
    package let valueSeed: UInt64
    package let perturbationSeed: UInt64

    package static let currentVersion = 1

    package init(fuzzCase: MetaFuzzCase, oracle: String, note: String?) {
        version = Self.currentVersion
        kind = .pipelineCase
        self.oracle = oracle
        self.note = note
        recipe = fuzzCase.recipe
        valueSeed = fuzzCase.valueSeed
        perturbationSeed = fuzzCase.perturbationSeed
    }
}

/// Thrown when a frozen record cannot be replayed as written — a stale schema version, not an oracle violation.
public struct FrozenCaseVersionMismatch: Error, CustomStringConvertible {
    public let description: String

    package init(_ description: String) {
        self.description = description
    }
}

public extension MetaFuzz {
    /// Freezes a fuzz case as a reproducer record, ready to commit into the harness's `Regressions/` directory.
    ///
    /// - Parameters:
    ///   - fuzzCase: The case that violated an oracle — the original, not the reduced form, so the record does not depend on the reducer that may itself be the defect.
    ///   - violation: The oracle violation the case produced. Its type name becomes the record's provenance.
    ///   - note: Free-form provenance, for example the defect and the PR that fixed it.
    /// - Returns: Pretty-printed JSON with stable key ordering, so committed records diff cleanly.
    static func freeze(_ fuzzCase: MetaFuzzCase, violation: some Error, note: String? = nil) throws -> Data {
        let record = MetaFuzzFrozenCase(
            fuzzCase: fuzzCase,
            oracle: String(describing: type(of: violation)),
            note: note
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(record)
    }

    /// How many freeze candidates one oracle may accumulate per findings directory. A single engine defect can violate its oracle on thousands of cases per run; a handful of reproducers is what a human freezes, and the fault inventory holds the full accounting.
    package static let findingsPerOracleCap = 25

    /// Recorded filenames per findings directory, seeded from one disk listing on the directory's first finding and extended as this process writes.
    ///
    /// The harness calls ``recordFinding(_:violation:in:)`` from inside the property closure, which runs inside the fuzz loop's coverage-attribution bracket. Anything expensive there lands in the run's property-time bucket and, in a whole-graph-instrumented build like this harness's, in the attempt's coverage signature as well. A hot oracle violation fires on a large fraction of attempts, so a repeat finding must cost a set lookup, not a directory scan and a rewrite. Seeding from disk keeps ``findingsPerOracleCap`` a bound on the directory rather than on the process, so repeated harness runs against the same directory cannot accumulate past it.
    private static let recordedFindingNames = SendableBox<[String: Set<String>]>([:])

    /// Forgets every recorded name, so the next finding in any directory re-seeds from disk.
    ///
    /// The cache is keyed by directory path and never evicted, which is right for a harness process that writes into a handful of directories and wrong for a test that wants to observe seeding twice against the same one. Exposed so those tests can target the mechanism instead of minting a fresh directory to escape it.
    package static func forgetRecordedFindings() {
        recordedFindingNames.value = [:]
    }

    /// Writes a frozen reproducer for a violating case into `directory` and returns the file URL, or `nil` when the write fails, the oracle's cap is reached, or this case was already recorded — by this process or by an earlier run against the same directory.
    ///
    /// The harness's fuzz entries call this from the property closure so findings survive the run as machine-readable freeze candidates, ready to commit into `Regressions/` alongside the fix. The filename folds in the violated oracle and a stable hash of the case, so repeat findings are recorded once, and each oracle stops recording at ``findingsPerOracleCap`` files. Write failures are swallowed deliberately — recording is a side channel and must never turn a real finding into an I/O error — and a failed write stays claimed, so a permanently unwritable directory cannot re-run the encoder on every attempt. The case is lost for the process's life; the fault inventory still counts it.
    @discardableResult
    static func recordFinding(_ fuzzCase: MetaFuzzCase, violation: some Error, in directory: URL) -> URL? {
        let oracle = "\(type(of: violation))"
        let name = "\(oracle)-\(stableHash(of: fuzzCase.description)).json"
        let directoryKey = directory.standardizedFileURL.path
        let shouldWrite = recordedFindingNames.withValue { namesByDirectory -> Bool in
            var names = namesByDirectory[directoryKey]
                ?? Set((try? FileManager.default.contentsOfDirectory(atPath: directoryKey)) ?? [])
            let canRecord = names.contains(name) == false
                && names.count(where: { $0.hasPrefix("\(oracle)-") }) < findingsPerOracleCap
            if canRecord {
                names.insert(name)
            }
            // Written back on both paths: a directory whose cap is already full still owes its seeded listing to the next call.
            namesByDirectory[directoryKey] = names
            return canRecord
        }
        guard shouldWrite, let data = try? freeze(fuzzCase, violation: violation) else {
            return nil
        }
        let file = directory.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            return file
        } catch {
            return nil
        }
    }

    /// Replays a frozen record: decodes it, gates on the schema version, and re-runs the oracle roster.
    ///
    /// Throws the oracle violation if the defect has been reintroduced, a decoding error if the record no longer parses, and ``FrozenCaseVersionMismatch`` if the schema has moved on. Returns normally when every oracle holds — the frozen defect stays fixed.
    static func replay(_ data: Data) throws {
        let record = try JSONDecoder().decode(MetaFuzzFrozenCase.self, from: data)
        guard record.version == MetaFuzzFrozenCase.currentVersion else {
            throw FrozenCaseVersionMismatch(
                "record version \(record.version) does not match current \(MetaFuzzFrozenCase.currentVersion); migrate or retire the record (oracle: \(record.oracle), note: \(record.note ?? "none"))"
            )
        }
        switch record.kind {
            case .pipelineCase:
                let fuzzCase = MetaFuzzCase(
                    recipe: record.recipe,
                    valueSeed: record.valueSeed,
                    perturbationSeed: record.perturbationSeed
                )
                try check(fuzzCase)
        }
    }
}

// MARK: - Stable Hash

/// The finding's filename hash, rendered in radix 36. Folded with ``Xoshiro256/fold(_:mixing:)`` (the same stable byte fold behind ``Gen/sourceFingerprint(fileID:line:column:)``) because `Hasher` is per-process randomized and a finding's filename must be stable across runs so repeats overwrite.
private func stableHash(of string: String) -> String {
    var hash: UInt64 = 0
    for byte in string.utf8 {
        hash = Xoshiro256.fold(hash, mixing: UInt64(byte))
    }
    return String(hash, radix: 36)
}
