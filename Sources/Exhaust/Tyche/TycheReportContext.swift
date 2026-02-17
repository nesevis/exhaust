import Foundation

/// Thread-safe context for collecting Tyche reporting data
public final class TycheReportContext {
    // MARK: - Thread-Local Storage

    private static let contextKey = "TycheReportContext"

    public static var current: TycheReportContext? {
        get {
            Thread.current.threadDictionary[contextKey] as? TycheReportContext
        }
        set {
            if let newValue {
                Thread.current.threadDictionary[contextKey] = newValue
            } else {
                Thread.current.threadDictionary.removeObject(forKey: contextKey)
            }
        }
    }

    // MARK: - Properties

    private let queue = DispatchQueue(label: "com.exhaust.tyche.reportcontext", attributes: .concurrent)
    private let reporters: [TycheReporter]

    // Thread-safe collections
    private var _generationEvents: [GenerationEvent] = []
    private var _shrinkingEvents: [ShrinkingEvent] = []
    private var _testOutcomes: [TestOutcome] = []
    private var _startTime: Date

    // MARK: - Initialization

    public init(reporters: [TycheReporter]) {
        self.reporters = reporters
        _startTime = Date()
    }

    // MARK: - Public API

    /// Execute a block of code with Tyche reporting enabled
    public static func withReporting<T>(
        reporters: [TycheReporter],
        operation: () throws -> T,
    ) rethrows -> T {
        let context = TycheReportContext(reporters: reporters)
        let previousContext = current
        current = context

        defer {
            current = previousContext
            context.finalizeAndReport()
        }

        return try operation()
    }

    /// Execute a block of code with Tyche reporting enabled (async version)
    public static func withReporting<T>(
        reporters: [TycheReporter],
        operation: () async throws -> T,
    ) async rethrows -> T {
        let context = TycheReportContext(reporters: reporters)
        let previousContext = current
        current = context

        defer {
            current = previousContext
            context.finalizeAndReport()
        }

        return try await operation()
    }

    // MARK: - Event Recording

    /// Record a value generation event
    public func recordGeneration(_ value: some Any, metadata: GenerationMetadata) {
        let event = GenerationEvent(value: value, metadata: metadata)
        queue.async(flags: .barrier) {
            self._generationEvents.append(event)
        }
    }

    /// Record a shrinking step
    public func recordShrinkStep(from: Any, to: Any, metadata: ShrinkingMetadata) {
        let event = ShrinkingEvent(from: from, to: to, metadata: metadata)
        queue.async(flags: .barrier) {
            self._shrinkingEvents.append(event)
        }
    }

    /// Record a test outcome
    public func recordTestOutcome(_ outcome: TestOutcome) {
        queue.async(flags: .barrier) {
            self._testOutcomes.append(outcome)
        }
    }

    // MARK: - Report Generation

    /// Generate a comprehensive report from collected data
    public func generateReport() -> TycheReport {
        queue.sync {
            let analyzer = TycheAnalyzer()
            let endTime = Date()
            let totalDuration = endTime.timeIntervalSince(_startTime)

            let generationReport = analyzer.analyzeGeneration(_generationEvents, duration: totalDuration)
            let shrinkingReport = analyzer.analyzeShrinking(_shrinkingEvents, duration: totalDuration)
            let testRunReport = analyzer.analyzeTestRuns(_testOutcomes, duration: totalDuration)

            return TycheReport(
                generationReport: generationReport,
                shrinkingReport: shrinkingReport,
                testRunReport: testRunReport,
                reportTimestamp: endTime,
            )
        }
    }

    // MARK: - Private Methods

    private func finalizeAndReport() {
        let report = generateReport()

        // Notify all reporters
        for reporter in reporters {
            reporter.report(report)
        }
    }
}

// MARK: - Internal Event Types

struct GenerationEvent {
    let value: Any
    let metadata: GenerationMetadata

    init(value: some Any, metadata: GenerationMetadata) {
        self.value = value
        self.metadata = metadata
    }
}

struct ShrinkingEvent {
    let from: Any
    let to: Any
    let metadata: ShrinkingMetadata
}

// MARK: - Convenience Extensions

public extension TycheReportContext {
    /// Quick setup for console reporting
    static func withConsoleReporting<T>(
        operation: () throws -> T,
    ) rethrows -> T {
        try withReporting(reporters: [ConsoleReporter()], operation: operation)
    }

    /// Quick setup for JSON file reporting
    static func withJSONReporting<T>(
        to url: URL,
        operation: () throws -> T,
    ) rethrows -> T {
        try withReporting(reporters: [JSONReporter(outputURL: url)], operation: operation)
    }

    /// Quick setup for multiple reporters
    static func withMultipleReporters<T>(
        console: Bool = false,
        jsonURL: URL? = nil,
        csvURL: URL? = nil,
        operation: () throws -> T,
    ) rethrows -> T {
        var reporters: [TycheReporter] = []

        if console {
            reporters.append(ConsoleReporter())
        }

        if let jsonURL {
            reporters.append(JSONReporter(outputURL: jsonURL))
        }

        if let csvURL {
            reporters.append(CSVReporter(outputURL: csvURL))
        }

        return try withReporting(reporters: reporters, operation: operation)
    }
}

// MARK: - Static Helpers

public extension TycheReportContext {
    /// Check if reporting is currently enabled
    static var isReportingEnabled: Bool {
        current != nil
    }

    /// Safely record generation event if reporting is enabled
    static func safeRecordGeneration(_ value: some Any, metadata: GenerationMetadata) {
        current?.recordGeneration(value, metadata: metadata)
    }

    /// Safely record shrinking event if reporting is enabled
    static func safeRecordShrinkStep(from: Any, to: Any, metadata: ShrinkingMetadata) {
        current?.recordShrinkStep(from: from, to: to, metadata: metadata)
    }

    /// Safely record test outcome if reporting is enabled
    static func safeRecordTestOutcome(_ outcome: TestOutcome) {
        current?.recordTestOutcome(outcome)
    }
}
