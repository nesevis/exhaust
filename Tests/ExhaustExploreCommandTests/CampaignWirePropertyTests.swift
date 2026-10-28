import Exhaust
import ExhaustSupport
import Foundation
import Testing
@testable import ExhaustExploreCommand

@Suite("Campaign wire properties")
struct CampaignWirePropertyTests: CampaignReportsFixtures {
    @Test("Fields that concatenate to the same text keep distinct fingerprints")
    func fieldBoundariesSeparateIdentities() {
        let gen = #gen(WireGenerators.fieldPieces, WireGenerators.cuts, WireGenerators.cuts)
        #exhaust(gen) { pieces, firstCuts, secondCuts in
            let first = FieldPartition.joining(pieces, at: firstCuts)
            let second = FieldPartition.joining(pieces, at: secondCuts)
            // Two distinct encodings can collide only through a 64-bit hash collision.
            return first == second || StableHash.fields(first) != StableHash.fields(second)
        }
    }

    @Test("Relative paths follow a lexical path model and reject everything outside the output root")
    func relativePathsFollowLexicalModel() throws {
        let scratch = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: scratch) }
        // Six levels of nesting let the six parent steps a path can draw climb without leaving the scratch directory. Digit names have no case variants, so a case-insensitive file system cannot alias a generated name to an existing directory.
        let root = scratch.appendingPathComponent("1/2/3/4/5/0")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = CampaignPaths(root: root)
        #exhaust(WireGenerators.pathSteps) { steps in
            let file = steps.reduce(root) { url, step in
                url.appendingPathComponent(step.component)
            }
            let actual = try? paths.relative(file)
            return actual == PathModel.relative(root: root.pathComponents, steps: steps)
        }
    }

    @Test("Collection streams every published event once, in its campaign's order, whatever order spool files arrive in")
    func collectionPreservesCampaignOrder() {
        let gen = #gen(WireGenerators.eventCounts, WireGenerators.arrivalKeys, WireGenerators.collectionPoints)
        #exhaust(gen) { counts, keys, collectsAfter in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let reports = try makeReports(directory)
            try reports.prepare()
            let published = SpoolArrival.events(counts: counts) { fixtureRecord(id: $0) }
            let arrivals = published.indices.sorted { (keys[$0], $0) < (keys[$1], $1) }
            for (step, index) in arrivals.enumerated() {
                let event = published[index]
                try JSONEncoder().encode(event)
                    .write(to: CampaignWire.jsonURL(in: reports.events.spool, id: event.eventID), options: .atomic)
                if collectsAfter[step] {
                    reports.events.collect()
                }
            }
            try reports.finish()
            let lines = try readStream(reports)
            let campaignEvents = lines.map(\.event).filter { $0.campaignID != nil }
            let eachCampaignInOrder = counts.indices.allSatisfy { campaign in
                let sequences = campaignEvents
                    .filter { $0.campaignID == SpoolArrival.campaignID(campaign) }
                    .map(\.campaignSequence)
                return sequences == (0 ..< counts[campaign]).map(Int?.some)
            }
            return reports.events.errors.isEmpty
                && lines.map(\.sequence) == Array(lines.indices)
                && Set(lines.map(\.event.eventID)).count == lines.count
                && campaignEvents.count == published.count
                && eachCampaignInOrder
        }
    }
}

// MARK: - Property Generators

private enum WireGenerators {
    /// Pieces drawn often from the length-prefix vocabulary, so that a piece can mimic another field's encoded length and separator.
    static var fieldPieces: ReflectiveGenerator<[String]> {
        let vocabulary = CharacterSet(charactersIn: "0123456789:")
        let prefixLike = #gen(.string(from: vocabulary, length: 0 ... 3))
        let other = #gen(.string(from: vocabulary.inverted, length: 0 ... 3))
        let piece = #gen(.oneOf(prefixLike, other))
        return piece.array(length: 1 ... 6)
    }

    /// One cut flag per gap between the at most six pieces.
    static var cuts: ReflectiveGenerator<[Bool]> {
        ReflectiveGenerator<Bool>.bool().array(length: 5)
    }

    /// One to four campaigns, each publishing one to four events, so at most 16 events arrive.
    static var eventCounts: ReflectiveGenerator<[Int]> {
        #gen(.int(in: 1 ... 4).array(length: 1 ... 4))
    }

    /// One arrival key per possible event. Arrival sorts by key and breaks ties by publication order, so every interleaving of the campaigns' files is reachable.
    static var arrivalKeys: ReflectiveGenerator<[Int]> {
        #gen(.int(in: 0 ... 15).array(length: 16))
    }

    /// Whether the collector lists the spool after each arrival, so partial listings interleave with publication.
    static var collectionPoints: ReflectiveGenerator<[Bool]> {
        ReflectiveGenerator<Bool>.bool().array(length: 16)
    }

    /// Steps that leave, re-enter, and step beside the root. The fixed names collide with the root's own directory names and with a sibling that shares its prefix; the general branch covers the rest of Unicode except path separators and the drive separator.
    static var pathSteps: ReflectiveGenerator<[PathStep]> {
        let collisions = ReflectiveGenerator<String>.element(from: ["0", "0-other", "1", "5"])
        let general = ReflectiveGenerator<String>
            .string(from: CharacterSet(charactersIn: "/\\:\0").inverted, length: 1 ... 6)
            .filter(.rejectionSampling) { $0 != "." && $0 != ".." }
        let name = ReflectiveGenerator<String>.oneOf(collisions, general).map(PathStep.name)
        let step: ReflectiveGenerator<PathStep> = .oneOf(
            weighted: (1, .just(.current)),
            (3, .just(.parent)),
            (4, name)
        )
        return step.array(length: 0 ... 6)
    }
}

// MARK: - Supporting Types

/// Builds the spool events the runtime would publish for each campaign: a start, then further events in campaign sequence order.
private enum SpoolArrival {
    static func campaignID(_ campaign: Int) -> String {
        "campaign-\(campaign)"
    }

    static func events(counts: [Int], record: (String) -> CampaignRecord) -> [CampaignEvent] {
        counts.enumerated().flatMap { entry in
            let id = campaignID(entry.offset)
            return (0 ..< entry.element).map { index in
                let payload: CampaignEventPayload = switch index {
                    case 0:
                        .campaignStarted(record(id))
                    default:
                        .campaignFinished(record(id))
                }
                return CampaignEvent(
                    eventID: CampaignWire.eventID(campaignID: id, sequence: index),
                    campaignID: id,
                    campaignSequence: index,
                    timestamp: 0,
                    payload: payload
                )
            }
        }
    }
}

/// One component appended to the output root.
private enum PathStep {
    case current
    case parent
    case name(String)

    var component: String {
        switch self {
            case .current:
                "."
            case .parent:
                ".."
            case let .name(name):
                name
        }
    }
}

// MARK: - Helpers

/// Regroups pieces into fields: a cut starts a new field, otherwise the piece extends the previous one.
private enum FieldPartition {
    static func joining(_ pieces: [String], at cuts: [Bool]) -> [String] {
        var fields = [pieces[0]]
        for (piece, cut) in zip(pieces.dropFirst(), cuts) {
            switch cut {
                case true:
                    fields.append(piece)
                case false:
                    fields[fields.count - 1] += piece
            }
        }
        return fields
    }
}

/// Resolves `.` and `..` textually, which is what the output root's containment depends on when no symlinks are involved.
private enum PathModel {
    static func relative(root: [String], steps: [PathStep]) -> String? {
        var components = root
        for step in steps {
            switch step {
                case .current:
                    break
                case .parent:
                    components.removeLast()
                case let .name(name):
                    components.append(name)
            }
        }
        guard components.starts(with: root) else {
            return nil
        }
        let suffix = components.dropFirst(root.count)
        guard suffix.isEmpty == false else {
            return "."
        }
        return suffix.joined(separator: "/")
    }
}
