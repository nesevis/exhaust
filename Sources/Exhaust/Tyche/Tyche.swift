import Foundation
@_spi(ExhaustInternal) import ExhaustCore

// MARK: - Main Tyche API

/// Main entry point for Tyche reporting functionality
public enum Tyche {
    // MARK: - Convenience Methods

    /// Run a test with console reporting enabled
    /// - Parameters:
    ///   - verbosity: Level of detail in console output
    ///   - operation: The test operation to run
    /// - Returns: The result of the operation
    public static func withConsoleReporting<T>(
        verbosity: ConsoleReporter.ConsoleVerbosity = .detailed,
        operation: () throws -> T,
    ) rethrows -> T {
        let reporter = ConsoleReporter(verbosity: verbosity)
        return try TycheReportContext.withReporting(reporters: [reporter], operation: operation)
    }

    /// Run a test with JSON file reporting enabled
    /// - Parameters:
    ///   - outputPath: Path where JSON report will be written
    ///   - prettyPrint: Whether to format JSON with indentation
    ///   - operation: The test operation to run
    /// - Returns: The result of the operation
    public static func withJSONReporting<T>(
        outputPath: String,
        prettyPrint: Bool = true,
        operation: () throws -> T,
    ) rethrows -> T {
        let url = URL(fileURLWithPath: outputPath)
        let reporter = JSONReporter(outputURL: url, prettyPrint: prettyPrint)
        return try TycheReportContext.withReporting(reporters: [reporter], operation: operation)
    }

    /// Run a test with CSV file reporting enabled
    /// - Parameters:
    ///   - outputPath: Path where CSV report will be written
    ///   - operation: The test operation to run
    /// - Returns: The result of the operation
    public static func withCSVReporting<T>(
        outputPath: String,
        operation: () throws -> T,
    ) rethrows -> T {
        let url = URL(fileURLWithPath: outputPath)
        let reporter = CSVReporter(outputURL: url)
        return try TycheReportContext.withReporting(reporters: [reporter], operation: operation)
    }

    /// Run a test with HTML file reporting enabled
    /// - Parameters:
    ///   - outputPath: Path where HTML report will be written
    ///   - includeCharts: Whether to include chart visualizations
    ///   - operation: The test operation to run
    /// - Returns: The result of the operation
    public static func withHTMLReporting<T>(
        outputPath: String,
        includeCharts: Bool = true,
        operation: () throws -> T,
    ) rethrows -> T {
        let url = URL(fileURLWithPath: outputPath)
        let reporter = HTMLReporter(outputURL: url, includeCharts: includeCharts)
        return try TycheReportContext.withReporting(reporters: [reporter], operation: operation)
    }

    /// Run a test with multiple reporters enabled
    /// - Parameters:
    ///   - reporters: Array of reporters to use
    ///   - operation: The test operation to run
    /// - Returns: The result of the operation
    public static func withReporting<T>(
        reporters: [TycheReporter],
        operation: () throws -> T,
    ) rethrows -> T {
        try TycheReportContext.withReporting(reporters: reporters, operation: operation)
    }

    /// Run a test with customizable reporting options
    /// - Parameters:
    ///   - console: Whether to enable console reporting
    ///   - consoleVerbosity: Level of console output detail
    ///   - jsonPath: Optional path for JSON output
    ///   - csvPath: Optional path for CSV output
    ///   - htmlPath: Optional path for HTML output
    ///   - operation: The test operation to run
    /// - Returns: The result of the operation
    public static func withMultipleReports<T>(
        console: Bool = true,
        consoleVerbosity: ConsoleReporter.ConsoleVerbosity = .detailed,
        jsonPath: String? = nil,
        csvPath: String? = nil,
        htmlPath: String? = nil,
        operation: () throws -> T,
    ) rethrows -> T {
        var reporters: [TycheReporter] = []

        if console {
            reporters.append(ConsoleReporter(verbosity: consoleVerbosity))
        }

        if let jsonPath {
            let url = URL(fileURLWithPath: jsonPath)
            reporters.append(JSONReporter(outputURL: url))
        }

        if let csvPath {
            let url = URL(fileURLWithPath: csvPath)
            reporters.append(CSVReporter(outputURL: url))
        }

        if let htmlPath {
            let url = URL(fileURLWithPath: htmlPath)
            reporters.append(HTMLReporter(outputURL: url))
        }

        return try TycheReportContext.withReporting(reporters: reporters, operation: operation)
    }

    // MARK: - Async Support

    /// Run an async test with console reporting enabled
    /// - Parameters:
    ///   - verbosity: Level of detail in console output
    ///   - operation: The async test operation to run
    /// - Returns: The result of the operation
    public static func withConsoleReporting<T>(
        verbosity: ConsoleReporter.ConsoleVerbosity = .detailed,
        operation: () async throws -> T,
    ) async rethrows -> T {
        let reporter = ConsoleReporter(verbosity: verbosity)
        return try await TycheReportContext.withReporting(reporters: [reporter], operation: operation)
    }

    /// Run an async test with JSON file reporting enabled
    /// - Parameters:
    ///   - outputPath: Path where JSON report will be written
    ///   - prettyPrint: Whether to format JSON with indentation
    ///   - operation: The async test operation to run
    /// - Returns: The result of the operation
    public static func withJSONReporting<T>(
        outputPath: String,
        prettyPrint: Bool = true,
        operation: () async throws -> T,
    ) async rethrows -> T {
        let url = URL(fileURLWithPath: outputPath)
        let reporter = JSONReporter(outputURL: url, prettyPrint: prettyPrint)
        return try await TycheReportContext.withReporting(reporters: [reporter], operation: operation)
    }

    /// Run an async test with multiple reporters enabled
    /// - Parameters:
    ///   - reporters: Array of reporters to use
    ///   - operation: The async test operation to run
    /// - Returns: The result of the operation
    public static func withReporting<T>(
        reporters: [TycheReporter],
        operation: () async throws -> T,
    ) async rethrows -> T {
        try await TycheReportContext.withReporting(reporters: reporters, operation: operation)
    }

    // MARK: - Property-Based Testing Integration

    // Note: Property-based testing methods are available but use internal types
    // They will be exposed through the main library's public API

    // MARK: - Utility Methods

    /// Check if Tyche reporting is currently enabled
    /// - Returns: True if reporting is active, false otherwise
    public static var isReportingEnabled: Bool {
        TycheReportContext.isReportingEnabled
    }

    /// Manually generate a report from the current context
    /// - Returns: Current report or nil if no context is active
    public static func generateCurrentReport() -> TycheReport? {
        TycheReportContext.current?.generateReport()
    }

    /// Record a custom generation event (for advanced users)
    /// - Parameters:
    ///   - value: The generated value
    ///   - metadata: Metadata about the generation
    public static func recordGeneration(_ value: some Any, metadata: GenerationMetadata) {
        TycheReportContext.safeRecordGeneration(value, metadata: metadata)
    }

    /// Record a custom shrinking event (for advanced users)
    /// - Parameters:
    ///   - from: Original value
    ///   - to: Shrunk value
    ///   - metadata: Metadata about the shrinking step
    public static func recordShrinkStep(from: Any, to: Any, metadata: ShrinkingMetadata) {
        TycheReportContext.safeRecordShrinkStep(from: from, to: to, metadata: metadata)
    }

    /// Record a custom test outcome (for advanced users)
    /// - Parameter outcome: The test outcome to record
    public static func recordTestOutcome(_ outcome: TestOutcome) {
        TycheReportContext.safeRecordTestOutcome(outcome)
    }
}

// MARK: - Property Test Result

/// Result of running property-based tests with Tyche
public struct PropertyTestResult<T> {
    /// Total number of tests that were run
    public let totalTests: Int

    /// Number of tests that passed
    public let successCount: Int

    /// Number of tests that failed
    public let failureCount: Int

    /// Original counterexamples that caused failures
    public let originalCounterexamples: [T]

    /// Shrunk counterexamples (minimal failing cases)
    public let shrunkCounterexamples: [T]

    /// Success rate as a percentage (0.0 to 1.0)
    public let successRate: Double

    /// Whether all tests passed
    public var allTestsPassed: Bool {
        failureCount == 0
    }

    /// Human-readable summary of the test results
    public var summary: String {
        let passRate = String(format: "%.1f%%", successRate * 100)
        if allTestsPassed {
            return "✅ All \(totalTests) tests passed (\(passRate))"
        } else {
            return "❌ \(failureCount) of \(totalTests) tests failed (\(passRate) pass rate)"
        }
    }
}

// MARK: - Extensions for Common Use Cases

public extension Tyche {
    /// Demonstrate basic reporting functionality
    /// - Parameters:
    ///   - operation: The operation to run with reporting
    /// - Returns: The result of the operation
    static func demonstrateReporting<T>(
        operation: () -> T,
    ) -> T {
        TycheReportContext.withReporting(reporters: [ConsoleReporter(verbosity: .summary)]) {
            operation()
        }
    }
}
