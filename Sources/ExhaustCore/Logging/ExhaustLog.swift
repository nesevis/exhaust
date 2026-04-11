//
//  ExhaustLog.swift
//  Exhaust
//
//  Created by Codex on 21/2/2026.
//

import Foundation
import OSLog

/// Log verbosity level for Exhaust test runs.
public enum LogLevel: Int, CaseIterable, Comparable, Sendable {
    case trace = 0
    case debug
    case info
    case notice
    case warning
    case error
    case critical

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

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
}

/// Log output format for Exhaust test runs.
public enum LogFormat: String, Sendable {
    case keyValue
    case jsonl
}

package enum ExhaustLog {
    package enum Category: String, CaseIterable, Hashable, Sendable {
        case core
        case extensions
        case generation
        case replay
        case reflection
        case materialize
        case reducer
        case adaptation
        case propertyTest
    }

    package struct Configuration: Sendable {
        package var isEnabled: Bool
        package var minimumLevel: LogLevel
        package var categoryMinimumLevels: [Category: LogLevel]
        package var format: LogFormat

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

        package mutating func setMinimumLevel(_ level: LogLevel, for category: Category) {
            categoryMinimumLevels[category] = level
        }

        package mutating func clearMinimumLevel(for category: Category) {
            categoryMinimumLevels[category] = nil
        }
    }

    package static var configuration: Configuration {
        _configuration
    }

    @inline(__always)
    package static func isEnabled(_ level: LogLevel, for category: Category = .core) -> Bool {
        shouldLog(level, category: category, configuration: _configuration)
    }

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
        print(rendered)
//        logger(for: category).log(level: level.osLogType, "\(rendered, privacy: .public)")
    }

    private static let subsystem = "com.exhaust"
    @TaskLocal private static var _configuration = Configuration()

    package static func withConfiguration<Result>(
        _ configuration: Configuration,
        body: () throws -> Result
    ) rethrows -> Result {
        try $_configuration.withValue(configuration) { try body() }
    }

    package static func withConfiguration<Result>(
        _ configuration: Configuration,
        body: () async throws -> Result
    ) async rethrows -> Result {
        try await $_configuration.withValue(configuration) { try await body() }
    }

    private static let coreLogger = Logger(subsystem: subsystem, category: Category.core.rawValue)
    private static let extensionsLogger = Logger(
        subsystem: subsystem,
        category: Category.extensions.rawValue
    )
    private static let generationLogger = Logger(
        subsystem: subsystem,
        category: Category.generation.rawValue
    )
    private static let replayLogger = Logger(
        subsystem: subsystem,
        category: Category.replay.rawValue
    )
    private static let reflectionLogger = Logger(
        subsystem: subsystem,
        category: Category.reflection.rawValue
    )
    private static let materializeLogger = Logger(
        subsystem: subsystem,
        category: Category.materialize.rawValue
    )
    private static let reducerLogger = Logger(
        subsystem: subsystem,
        category: Category.reducer.rawValue
    )
    private static let adaptationLogger = Logger(
        subsystem: subsystem,
        category: Category.adaptation.rawValue
    )
    private static let propertyTestLogger = Logger(
        subsystem: subsystem,
        category: Category.propertyTest.rawValue
    )

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
