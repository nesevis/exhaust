import ExhaustCore
import ExhaustSupport
import Foundation

#if canImport(Testing)
    #if canImport(ObjectiveC)
        @_weakLinked import Testing
    #else
        import Testing // swiftlint:disable:this duplicate_imports
    #endif
#endif

/// Resolves task-local attribution and recovery storage once, before the campaign leaves the test task.
package struct FuzzCampaignContext: Sendable {
    let fileID: StaticString
    let filePath: StaticString
    let line: UInt
    let column: UInt
    let testID: String?
    let testName: String?
    let seed: UInt64?
    let kind: FuzzCampaignKind
    /// Where the explore command collects campaign records; nil outside a command run.
    let reportDirectory: URL?
    /// False under `EXHAUST_RESUME=0`, which ignores predecessor state but still writes checkpoints.
    let resumeEnabled: Bool
    package let configuration: FuzzCampaignConfiguration
    package let store: FuzzProgressStore

    package init(
        fileID: StaticString,
        filePath: StaticString,
        line: UInt,
        column: UInt,
        testID: String?,
        testName: String?,
        seed: UInt64?,
        kind: FuzzCampaignKind,
        time: TimeSpan,
        invalidReplayMessage: String? = nil,
        environment: [String: String]
    ) {
        self.fileID = fileID
        self.filePath = filePath
        self.line = line
        self.column = column
        self.testID = testID
        self.testName = testName
        self.seed = seed
        self.kind = kind
        reportDirectory = environment[CampaignWire.reportDirectoryKey].map { URL(fileURLWithPath: $0) }
        resumeEnabled = environment[CampaignWire.resumeKey] != "0"
        configuration = FuzzCampaignConfiguration(
            time: time,
            seed: seed,
            propertyModule: "\(fileID)".split(separator: "/").first.map(String.init) ?? "",
            invalidReplayMessage: invalidReplayMessage,
            environment: environment
        )
        let baseDirectory = environment[CampaignWire.stateDirectoryKey].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        store = FuzzProgressStore(
            fileID: fileID,
            line: line,
            column: column,
            testIdentity: testID,
            seed: seed,
            baseDirectory: baseDirectory
        )
    }

    /// Captures both forms of the Swift Testing name from the same task-local test instance.
    package static func resolve(
        fileID: StaticString,
        filePath: StaticString,
        line: UInt,
        column: UInt,
        seed: UInt64?,
        kind: FuzzCampaignKind,
        time: TimeSpan,
        invalidReplayMessage: String? = nil
    ) -> Self {
        #if canImport(Testing)
            let (testID, testName) = currentTestNames
        #else
            let testID: String? = nil
            let testName: String? = nil
        #endif
        return Self(
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column,
            testID: testID,
            testName: testName,
            seed: seed,
            kind: kind,
            time: time,
            invalidReplayMessage: invalidReplayMessage,
            environment: ProcessInfo.processInfo.environment
        )
    }

    var source: CampaignSource {
        CampaignSource(fileID: String(describing: fileID), line: line, column: column)
    }

    /// The report for a campaign that ends before searching, carrying the requested seed or zero when none was given.
    func emptyReport(_ termination: FuzzReport.Termination) -> FuzzReport {
        .empty(termination: termination, seed: seed ?? 0)
    }

    /// The validated run the core receives, or the report a rejected setting ends the campaign with. Every path into the core converts a rejection here, so none can disagree about the rejected report.
    var runResolution: FuzzRunResolution {
        switch configuration.resolution {
            case let .success(resolved):
                .resolved(resolved)
            case let .failure(error):
                .rejected(emptyReport(.invalidConfiguration(error.message)))
        }
    }

    /// Keeps finding-v1 compatible: fields are length-prefixed UTF-8 and the canonical reduced key excludes reduction-path metadata.
    package func findingID(_ cluster: FuzzReport.Cluster) -> String {
        "finding-v1-" + StableHash.fields([
            "finding-v1", testID ?? "", String(describing: fileID), String(line), String(column), kind.rawValue,
            cluster.reducedKey,
        ])
    }

    /// Uses the actual search seed, which may differ from the requested seed after recovery.
    package func attachmentPrefix(seed: UInt64, campaignID: String? = nil) -> String {
        "explore-time-\(attachmentName)-seed-\(seed)" + (campaignID.map { "-" + $0 } ?? "")
    }

    /// Reports setup and publication errors at the macro expansion that owns the campaign.
    func reportError(_ message: String) {
        Exhaust.reportError(message, fileID: fileID, filePath: filePath, line: line, column: column)
    }

    /// Warns at the macro expansion when a spec campaign's linearizability searches were abandoned or stalled, so a clean inventory is not mistaken for a judged one.
    func warnIfSearchesWentUnjudged(abandonedSearches: Int, stalledSearches: Int) {
        Exhaust.warnIfSearchesWentUnjudged(
            abandonedSearches: abandonedSearches,
            stalledSearches: stalledSearches,
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )
    }

    /// Bounds the encoded filename while retaining readable Unicode test names.
    private var attachmentName: String {
        var name = ""
        for scalar in (testName ?? "standalone").unicodeScalars {
            let part = switch CharacterSet.alphanumerics.contains(scalar) || "._-".unicodeScalars.contains(scalar) {
                case true:
                    String(scalar)
                case false:
                    "-"
            }
            guard name.utf8.count + part.utf8.count <= 120 else {
                break
            }
            name += part
        }
        let trimmed = name.trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))
        return switch trimmed.isEmpty {
            case true:
                "test"
            case false:
                trimmed
        }
    }

    #if canImport(Testing)
        private static var currentTestNames: (String?, String?) {
            #if canImport(ObjectiveC)
                guard #_hasSymbol(Test.current) else {
                    return (nil, nil)
                }
            #endif
            return loadedTestNames()
        }

        /// Keeps Test metadata out of the guarded caller's frame when the weakly linked framework is absent.
        @inline(never)
        private static func loadedTestNames() -> (String?, String?) {
            guard let test = Test.current else {
                return (nil, nil)
            }
            let identifier = String(describing: test.id)
            let name = test.id.nameComponents.map { String($0.prefix { $0 != "(" }) }.joined(separator: ".")
            return (identifier, name)
        }
    #endif
}

/// Splits a campaign's captured configuration into the two ways the search can begin.
enum FuzzRunResolution {
    /// The settings passed validation; the core runs with this seed and budget.
    case resolved(ResolvedFuzzRun)
    /// A setting was rejected; the campaign ends with this report without reserving its store.
    case rejected(FuzzReport)
}
