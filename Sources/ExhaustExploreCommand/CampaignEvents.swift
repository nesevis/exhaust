import ExhaustSupport
import Foundation

/// Serializes published spool files into one JSONL stream. Mutable collection state is protected by the lock, including access from the scoped timer and finalization thread.
final class CampaignEvents: @unchecked Sendable {
    let runID: String
    let path: URL
    let spool: URL
    private let paths: CampaignPaths
    private let lock = NSLock()
    private var sequence = 0
    private var collected: Set<String> = []
    private var nextCampaignSequence: [String: Int] = [:]
    private var collectionErrors: [String] = []

    var errors: [String] {
        lock.withLock { collectionErrors }
    }

    init(runID: String, path: URL, spool: URL, paths: CampaignPaths) {
        self.runID = runID
        self.path = path
        self.spool = spool
        self.paths = paths
    }

    /// Resets only this command's stream; previous run spools remain available for inspection.
    func prepare() throws {
        try lock.withLock {
            try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: true)
            try Data().write(to: path, options: .atomic)
        }
    }

    /// Publishes a command-owned event through the same sequencer as runtime events.
    func append(_ payload: CampaignEventPayload, campaignID: String? = nil) throws {
        try lock.withLock {
            try appendUnlocked(CampaignEvent(campaignID: campaignID, payload: payload))
        }
    }

    /// Collects while a test process waits for exit, then joins the timer queue before its caller can finalize the report.
    func collecting<Result>(during body: () throws -> Result) rethrows -> Result {
        let queue = DispatchQueue(label: "exhaust.campaign-events", qos: .utility)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [weak self] in
            self?.collect()
        }
        timer.schedule(deadline: .now(), repeating: .milliseconds(100))
        timer.resume()
        defer {
            timer.cancel()
            queue.sync {}
            collect()
        }
        return try body()
    }

    /// Retains collection failures for the final report instead of abandoning a running test process or masking its exit. An event whose predecessor has not been listed yet waits for a later collection.
    func collect() {
        lock.withLock {
            _ = collectPublished()
        }
    }

    /// Collects for the last time after the test process exits, so an event still waiting for its predecessor marks a permanent gap.
    func collectFinal() {
        lock.withLock {
            for name in collectPublished() {
                collected.insert(name)
                collectionErrors.append("\(name): Missing or out-of-order campaign event: \(name)")
            }
        }
    }

    /// Appends every listed event that is next in its campaign's order and returns the names of valid events still waiting for a predecessor.
    private func collectPublished() -> [String] {
        var waiting: [String] = []
        do {
            let files = try FileManager.default.contentsOfDirectory(at: spool, includingPropertiesForKeys: nil)
            for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
                where file.pathExtension == "json" && collected.contains(file.lastPathComponent) == false
            {
                if collect(file) == false {
                    waiting.append(file.lastPathComponent)
                }
            }
        } catch {
            let message = "Cannot collect campaign events: \(error)"
            if collectionErrors.contains(message) == false {
                collectionErrors.append(message)
            }
        }
        return waiting
    }

    /// Checks publication identity and order after Codable validates the envelope and the payload for its event type. Returns false only for a valid event whose predecessor is not collected yet; a directory listing concurrent with publication may miss an earlier file.
    private func collect(_ file: URL) -> Bool {
        do {
            var event = try JSONDecoder().decode(CampaignEvent.self, from: Data(contentsOf: file))
            guard event.schemaVersion == 1,
                  let campaignID = event.campaignID,
                  let index = event.campaignSequence, index >= 0,
                  event.eventID == CampaignWire.eventID(campaignID: campaignID, sequence: index),
                  event.eventID == file.deletingPathExtension().lastPathComponent
            else {
                throw CommandError("Invalid campaign event identity: \(file.lastPathComponent)")
            }
            switch event.payload {
                case .campaignStarted, .findingReported, .campaignFinished:
                    break
                case .runStarted, .phaseChanged, .campaignInterrupted, .runFinished:
                    throw CommandError("Unexpected runtime event: \(event.type.rawValue)")
            }
            guard index == nextCampaignSequence[campaignID, default: 0] else {
                return false
            }
            let records = spool.deletingLastPathComponent()
            try event.payload.relocate(
                recordFile: CampaignWire.jsonURL(in: records, id: campaignID),
                attachmentsDirectory: records.deletingLastPathComponent(),
                paths: paths
            )
            // Do not retry a failed append: the operating system may have accepted part of its data.
            collected.insert(file.lastPathComponent)
            try appendUnlocked(event)
            nextCampaignSequence[campaignID] = index + 1
        } catch {
            collected.insert(file.lastPathComponent)
            collectionErrors.append("\(file.lastPathComponent): \(error)")
        }
        return true
    }

    private func appendUnlocked(_ event: CampaignEvent) throws {
        let line = CampaignStreamEvent(runID: runID, sequence: sequence, event: event)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(line)
        data.append(0x0A)
        let handle = try FileHandle(forWritingTo: path)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        sequence += 1
    }
}

// MARK: - Runtime Paths

private extension CampaignEventPayload {
    /// Rewrites the runtime's spool-relative paths as paths relative to the output root. A finding carries no attachments, and command events carry no runtime paths.
    mutating func relocate(recordFile: URL, attachmentsDirectory: URL, paths: CampaignPaths) throws {
        switch self {
            case let .campaignStarted(record):
                self = try .campaignStarted(
                    paths.relocated(record, recordFile: recordFile, attachmentsDirectory: attachmentsDirectory)
                )
            case let .campaignFinished(record):
                self = try .campaignFinished(
                    paths.relocated(record, recordFile: recordFile, attachmentsDirectory: attachmentsDirectory)
                )
            case var .findingReported(finding):
                finding.recordPath = try paths.relative(recordFile)
                self = .findingReported(finding)
            case .runStarted, .phaseChanged, .campaignInterrupted, .runFinished:
                break
        }
    }
}
