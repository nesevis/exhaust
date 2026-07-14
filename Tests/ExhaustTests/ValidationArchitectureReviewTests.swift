import Foundation
import Testing

@Suite("Validation architecture review")
struct ValidationArchitectureReviewTests {
    @Test("Required validation workflows run before merge")
    func requiredValidationWorkflowsRunBeforeMerge() throws {
        let requiredWorkflowNames = [
            "explore-harness.yml",
            "meta-fuzz.yml",
            "test-linux.yml",
            "test-sequential.yml",
            "test-windows.yml",
            "test.yml",
            "xcframework-test.yml",
        ]

        let missingPreMergeTrigger = try requiredWorkflowNames.filter { workflowName in
            let contents = try workflowContents(named: workflowName)
            return contents.contains("pull_request:") == false
                && contents.contains("merge_group:") == false
        }

        #expect(missingPreMergeTrigger.isEmpty)
    }

    @Test("Static-analysis configurations are enforced by CI")
    func staticAnalysisConfigurationsAreEnforced() throws {
        let contents = try allWorkflowContents().lowercased()
        let requiredCommands = ["swiftlint", "swiftformat", "periphery"]
        let missingCommands = requiredCommands.filter { contents.contains($0) == false }

        #expect(missingCommands.isEmpty)
    }

    @Test("CI exercises the source package in release mode")
    func sourcePackageIsTestedInReleaseMode() throws {
        let workflowFileURLs = try allWorkflowFileURLs()
        let hasReleaseTest = try workflowFileURLs.contains { fileURL in
            let contents = try String(contentsOf: fileURL, encoding: .utf8)
            return contents.contains("swift test")
                && (contents.contains("--configuration release") || contents.contains("-c release"))
        }

        #expect(hasReleaseTest)
    }

    @Test("Macro validation rejects generated source changes")
    func macroValidationRejectsGeneratedSourceChanges() throws {
        let contents = try workflowContents(named: "test.yml")
        let hasDirtyTreeGuard = contents.contains("git diff --exit-code")
            || contents.contains("git diff --quiet")
            || contents.contains("git status --porcelain")

        #expect(hasDirtyTreeGuard)
    }
}

private func workflowContents(named workflowName: String) throws -> String {
    let fileURL = workflowsDirectoryURL.appendingPathComponent(workflowName)
    return try String(contentsOf: fileURL, encoding: .utf8)
}

private func allWorkflowContents() throws -> String {
    try allWorkflowFileURLs()
        .map { try String(contentsOf: $0, encoding: .utf8) }
        .joined(separator: "\n")
}

private func allWorkflowFileURLs() throws -> [URL] {
    try FileManager.default.contentsOfDirectory(
        at: workflowsDirectoryURL,
        includingPropertiesForKeys: nil
    )
    .filter { ["yml", "yaml"].contains($0.pathExtension) }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
}

private let workflowsDirectoryURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent(".github/workflows")
