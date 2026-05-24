//
//  ExhaustLog.swift
//  Exhaust
//
//  Created by Codex on 21/2/2026.
//

import Foundation

#if canImport(OSLog)
    import OSLog
#endif

/// Log verbosity level for Exhaust test runs.
public enum LogLevel: Int, CaseIterable, Comparable, Sendable {
    /// Logs fine-grained diagnostic detail such as individual choice values and branch selections.
    case trace = 0
    /// Logs internal state transitions useful for debugging generator and reducer behavior.
    case debug
    /// Logs high-level progress milestones such as phase transitions and pass completion.
    case info
    /// Logs notable events that may warrant attention but do not indicate errors.
    case notice
    /// Logs unexpected conditions that do not prevent execution but may affect results.
    case warning
    /// Logs failures that prevent a specific operation from completing.
    case error
    /// Logs unrecoverable failures that halt the entire test run.
    case critical

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    #if canImport(OSLog)
        /// Maps this level to the corresponding ``OSLogType`` for Apple's unified logging system.
        @available(macOS 11, iOS 14, tvOS 14, watchOS 7, *)
        package var osLogType: OSLogType {
            switch self {
                case .trace, .debug:
                    .debug
                case .info:
                    .info
                case .notice, .warning:
                    .default
                case .error:
                    .error
                case .critical:
                    .fault
            }
        }
    #endif
}

/// Log output format for Exhaust test runs.
public enum LogFormat: String, Sendable {
    /// Renders log entries as human-readable key-value pairs for console output.
    case keyValue
    /// Renders log entries as single-line JSON objects for machine-parseable output.
    case jsonl
}

/// Provides structured logging for Exhaust's internal subsystems.
package enum ExhaustLog {
    /// Identifies the subsystem that originated a log message.
    package enum Category: String, CaseIterable, Hashable, Sendable {
        /// Core framework infrastructure including the Freer Monad interpreter loop.
        case core
        /// User-facing generator extension methods and combinators.
        case extensions
        /// Forward-pass value generation from choice sequences.
        case generation
        /// Deterministic replay of a recorded choice sequence.
        case replay
        /// Backward-pass reflection that decomposes values into choice sequences.
        case reflection
        /// Guided materialization of choice sequences into concrete values.
        case materialize
        /// Choice-graph reducer and its encoders.
        case reducer
        /// CGS tuning, subdivision, and weight adaptation.
        case adaptation
        /// Top-level property test orchestration and result reporting.
        case propertyTest
    }

    /// Controls per-category log levels and output format.
    package struct Configuration: Sendable {
        /// Enables or disables all logging globally.
        package var isEnabled: Bool
        /// Minimum ``LogLevel`` applied to categories without an explicit override.
        package var minimumLevel: LogLevel
        /// Per-category minimum level overrides, taking precedence over ``minimumLevel``.
        package var categoryMinimumLevels: [Category: LogLevel]
        /// Output format used when rendering log entries.
        package var format: LogFormat

        /// Creates a logging configuration with the given settings.
        ///
        /// - Parameters:
        ///   - isEnabled: Whether logging is active. Defaults to `true`.
        ///   - minimumLevel: Global minimum level. Defaults to ``LogLevel/notice``.
        ///   - categoryMinimumLevels: Per-category overrides. Defaults to empty.
        ///   - format: Output format. Defaults to ``LogFormat/keyValue``.
        package init(
            isEnabled: Bool = true,
            minimumLevel: LogLevel = .notice,
            categoryMinimumLevels: [Category: LogLevel] = [:],
            format: LogFormat = .keyValue
        ) {
            self.isEnabled = isEnabled
            self.minimumLevel = minimumLevel
            self.categoryMinimumLevels = categoryMinimumLevels
            self.format = format
        }

        /// Sets the minimum log level for a specific category, overriding the global ``minimumLevel``.
        package mutating func setMinimumLevel(_ level: LogLevel, for category: Category) {
            categoryMinimumLevels[category] = level
        }

        /// Removes the per-category override so the category falls back to the global ``minimumLevel``.
        package mutating func clearMinimumLevel(for category: Category) {
            categoryMinimumLevels[category] = nil
        }
    }

    /// Returns the active logging configuration for the current task.
    package static var configuration: Configuration {
        _configuration
    }

    /// Returns whether a message at the given level and category would be emitted under the current configuration.
    @inline(__always)
    package static func isEnabled(_ level: LogLevel, for category: Category = .core) -> Bool {
        shouldLog(level, category: category, configuration: _configuration)
    }

    /// Emits a structured log entry at the specified level and category if logging is enabled.
    package static func log(
        _ level: LogLevel,
        category: Category = .core,
        event: String,
        _ message: @autoclosure @escaping () -> String = "",
        metadata: [String: String] = [:],
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        _log(
            level,
            category: category,
            event: event,
            message: message,
            metadata: metadata,
            file: file,
            line: line
        )
    }

    /// Emits a trace-level log entry.
    package static func trace(
        category: Category = .core,
        event: String,
        _ message: @autoclosure @escaping () -> String = "",
        metadata: [String: String] = [:],
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        _log(
            .trace,
            category: category,
            event: event,
            message: message,
            metadata: metadata,
            file: file,
            line: line
        )
    }

    /// Emits a debug-level log entry.
    package static func debug(
        category: Category = .core,
        event: String,
        _ message: @autoclosure @escaping () -> String = "",
        metadata: [String: String] = [:],
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        _log(
            .debug,
            category: category,
            event: event,
            message: message,
            metadata: metadata,
            file: file,
            line: line
        )
    }

    /// Emits an info-level log entry.
    package static func info(
        category: Category = .core,
        event: String,
        _ message: @autoclosure @escaping () -> String = "",
        metadata: [String: String] = [:],
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        _log(
            .info,
            category: category,
            event: event,
            message: message,
            metadata: metadata,
            file: file,
            line: line
        )
    }

    /// Emits a notice-level log entry.
    package static func notice(
        category: Category = .core,
        event: String,
        _ message: @autoclosure @escaping () -> String = "",
        metadata: [String: String] = [:],
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        _log(
            .notice,
            category: category,
            event: event,
            message: message,
            metadata: metadata,
            file: file,
            line: line
        )
    }

    /// Emits a warning-level log entry.
    package static func warning(
        category: Category = .core,
        event: String,
        _ message: @autoclosure @escaping () -> String = "",
        metadata: [String: String] = [:],
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        _log(
            .warning,
            category: category,
            event: event,
            message: message,
            metadata: metadata,
            file: file,
            line: line
        )
    }

    /// Emits an error-level log entry.
    package static func error(
        category: Category = .core,
        event: String,
        _ message: @autoclosure @escaping () -> String = "",
        metadata: [String: String] = [:],
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        _log(
            .error,
            category: category,
            event: event,
            message: message,
            metadata: metadata,
            file: file,
            line: line
        )
    }

    /// Emits a critical-level log entry.
    package static func critical(
        category: Category = .core,
        event: String,
        _ message: @autoclosure @escaping () -> String = "",
        metadata: [String: String] = [:],
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        _log(
            .critical,
            category: category,
            event: event,
            message: message,
            metadata: metadata,
            file: file,
            line: line
        )
    }

    private static func _log(
        _ level: LogLevel,
        category: Category,
        event: String,
        message: () -> String,
        metadata: [String: String],
        file: StaticString,
        line: UInt
    ) {
        let configuration = _configuration
        guard shouldLog(level, category: category, configuration: configuration) else {
            return
        }

        let rendered = render(
            level: level,
            category: category,
            event: event,
            message: message(),
            metadata: metadata,
            file: "\(file)",
            line: line,
            format: configuration.format
        )
        #if canImport(OSLog)
            if #available(macOS 11, iOS 14, tvOS 14, watchOS 7, *) {
                logger(for: category).log(level: level.osLogType, "\(rendered, privacy: .public)")
            } else {
                print(rendered)
            }
        #else
            print(rendered)
        #endif
    }

    private static let subsystem = "com.exhaust"
    @TaskLocal private static var _configuration = Configuration()

    /// Executes the synchronous closure with the given logging configuration scoped to the current task.
    package static func withConfiguration<Result>(
        _ configuration: Configuration,
        body: () throws -> Result
    ) rethrows -> Result {
        try $_configuration.withValue(configuration) { try body() }
    }

    /// Executes the asynchronous closure with the given logging configuration scoped to the current task.
    package static func withConfiguration<Result>(
        _ configuration: Configuration,
        body: () async throws -> Result
    ) async rethrows -> Result {
        try await $_configuration.withValue(configuration) { try await body() }
    }

    #if canImport(OSLog)
        @available(macOS 11, iOS 14, tvOS 14, watchOS 7, *)
        private static let coreLogger = Logger(subsystem: subsystem, category: Category.core.rawValue)
        @available(macOS 11, iOS 14, tvOS 14, watchOS 7, *)
        private static let extensionsLogger = Logger(
            subsystem: subsystem,
            category: Category.extensions.rawValue
        )
        @available(macOS 11, iOS 14, tvOS 14, watchOS 7, *)
        private static let generationLogger = Logger(
            subsystem: subsystem,
            category: Category.generation.rawValue
        )
        @available(macOS 11, iOS 14, tvOS 14, watchOS 7, *)
        private static let replayLogger = Logger(
            subsystem: subsystem,
            category: Category.replay.rawValue
        )
        @available(macOS 11, iOS 14, tvOS 14, watchOS 7, *)
        private static let reflectionLogger = Logger(
            subsystem: subsystem,
            category: Category.reflection.rawValue
        )
        @available(macOS 11, iOS 14, tvOS 14, watchOS 7, *)
        private static let materializeLogger = Logger(
            subsystem: subsystem,
            category: Category.materialize.rawValue
        )
        @available(macOS 11, iOS 14, tvOS 14, watchOS 7, *)
        private static let reducerLogger = Logger(
            subsystem: subsystem,
            category: Category.reducer.rawValue
        )
        @available(macOS 11, iOS 14, tvOS 14, watchOS 7, *)
        private static let adaptationLogger = Logger(
            subsystem: subsystem,
            category: Category.adaptation.rawValue
        )
        @available(macOS 11, iOS 14, tvOS 14, watchOS 7, *)
        private static let propertyTestLogger = Logger(
            subsystem: subsystem,
            category: Category.propertyTest.rawValue
        )
    #endif

    @inline(__always)
    private static func shouldLog(
        _ level: LogLevel,
        category: Category,
        configuration: Configuration
    ) -> Bool {
        guard configuration.isEnabled else {
            return false
        }
        let minimum = configuration.categoryMinimumLevels[category] ?? configuration.minimumLevel
        return level >= minimum
    }

    #if canImport(OSLog)
        @available(macOS 11, iOS 14, tvOS 14, watchOS 7, *)
        private static func logger(for category: Category) -> Logger {
            switch category {
                case .core:
                    coreLogger
                case .extensions:
                    extensionsLogger
                case .generation:
                    generationLogger
                case .replay:
                    replayLogger
                case .reflection:
                    reflectionLogger
                case .materialize:
                    materializeLogger
                case .reducer:
                    reducerLogger
                case .adaptation:
                    adaptationLogger
                case .propertyTest:
                    propertyTestLogger
            }
        }
    #endif

    private static func render(
        level: LogLevel,
        category: Category,
        event: String,
        message: String,
        metadata: [String: String],
        file: String,
        line: UInt,
        format: LogFormat
    ) -> String {
        switch format {
            case .keyValue:
                let metadataDescription = renderKeyValueMetadata(metadata)
                let messagePart = message.isEmpty ? "" : " \(message)"
                return "[\(category.rawValue)] [\(level)] [\(event)]\(messagePart)\(metadataDescription)"
            case .jsonl:
                return renderJSONLLogLine(
                    category: category,
                    level: level,
                    event: event,
                    message: message,
                    file: file,
                    line: line,
                    metadata: metadata
                )
        }
    }

    private static func renderKeyValueMetadata(_ metadata: [String: String]) -> String {
        guard metadata.isEmpty == false else {
            return ""
        }
        let pairs = metadata
            .sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        return " \(pairs)"
    }

    private static func renderJSONLLogLine(
        category: Category,
        level: LogLevel,
        event: String,
        message: String,
        file: String,
        line: UInt,
        metadata: [String: String]
    ) -> String {
        let logLine = JSONLLogLine(
            kind: "exhaust_log",
            category: category.rawValue,
            level: "\(level)",
            event: event,
            message: message,
            file: file,
            line: line,
            metadata: metadata
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(logLine),
              let json = String(data: data, encoding: .utf8)
        else {
            return "{\"kind\":\"exhaust_log\"}"
        }
        return json
    }
}

private struct JSONLLogLine: Encodable {
    let kind: String
    let category: String
    let level: String
    let event: String
    let message: String
    let file: String
    let line: UInt
    let metadata: [String: String]
}
