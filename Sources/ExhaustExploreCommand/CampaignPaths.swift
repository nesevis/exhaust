import ExhaustSupport
import Foundation

/// Converts artifact references to portable paths while rejecting paths that escape the output root.
struct CampaignPaths {
    let root: URL

    func relative(_ file: URL) throws -> String {
        let rootComponents = canonical(root).pathComponents
        let fileComponents = canonical(file).pathComponents
        guard fileComponents.starts(with: rootComponents) else {
            throw CommandError("Report path is outside the output root: \(file.nativePath)")
        }
        let remainder = fileComponents.dropFirst(rootComponents.count)
        return switch remainder.isEmpty {
            case true:
                "."
            case false:
                remainder.joined(separator: "/")
        }
    }

    /// Rewrites a runtime record's attachment names, which are relative to its run's attachment directory, and its record file as paths relative to the output root.
    func relocated(_ record: CampaignRecord, recordFile: URL, attachmentsDirectory: URL) throws -> CampaignRecord {
        var record = record
        record.recordPath = try relative(recordFile)
        record.attachments = try record.attachments.map { try relative(attachmentsDirectory.appendingPathComponent($0)) }
        return record
    }

    /// Resolves the existing ancestor first because Foundation may leave every symlink unresolved when the final attachment does not exist yet.
    private func canonical(_ file: URL) -> URL {
        var ancestor = file.standardizedFileURL
        var suffix: [String] = []
        while FileManager.default.fileExists(atPath: ancestor.path) == false {
            let parent = ancestor.deletingLastPathComponent()
            guard parent.path != ancestor.path else {
                break
            }
            suffix.append(ancestor.lastPathComponent)
            ancestor = parent
        }
        return suffix.reversed().reduce(ancestor.resolvingSymlinksInPath()) { path, component in
            path.appendingPathComponent(component)
        }
    }
}
