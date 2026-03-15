//
//  ExhaustLog.swift
//  Exhaust
//
//  Created by Codex on 21/2/2026.
//

import Foundation
import OSLog

public enum ExhaustLog {
    public enum Level: Int, CaseIterable, Comparable, Sendable {
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

        fileprivate var osLogType: OSLogType {
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

    public enum Category: String, CaseIterable, Hashable, Sendable {
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

    public enum Format: String, Sendable {
        case human
        case llmOptimized
    }

    public struct Configuration: Sendable {
        public var isEnabled: Bool
        public var minimumLevel: Level
        public var categoryMinimumLevels: [Category: Level]
        public var format: Format

        public init(
            isEnabled: Bool = true,
            minimumLevel: Level = .notice,
            categoryMinimumLevels: [Category: Level] = [:],
            format: Format = .human
        ) {
            self.isEnabled = isEnabled
            self.minimumLevel = minimumLevel
            self.categoryMinimumLevels = categoryMinimumLevels
            self.format = format
        }

        public mutating func setMinimumLevel(_ level: Level, for category: Category) {
            categoryMinimumLevels[category] = level
        }

        public mutating func clearMinimumLevel(for category: Category) {
            categoryMinimumLevels[category] = nil
        }
    }

    public static var configuration: Configuration {
        _configuration
    }

    public static func setConfiguration(_ configuration: Configuration) {
        _configuration = configuration
    }

    public static func updateConfiguration(_ update: (inout Configuration) -> Void) {
        update(&_configuration)
    }

    @inline(__always)
    public static func isEnabled(_ level: Level, for category: Category = .core) -> Bool {
        shouldLog(level, category: category, configuration: _configuration)
    }

    public static func log(
        _ level: Level,
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

    public static func trace(
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

    public static func debug(
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

    public static func info(
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

    public static func notice(
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

    public static func warning(
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

    public static func error(
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

    public static func critical(
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
        _ level: Level,
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
    private nonisolated(unsafe) static var _configuration = Configuration()

    private static let coreLogger = Logger(subsystem: subsystem, category: Category.core.rawValue)
    private static let extensionsLogger = Logger(subsystem: subsystem, category: Category.extensions.rawValue)
    private static let generationLogger = Logger(subsystem: subsystem, category: Category.generation.rawValue)
    private static let replayLogger = Logger(subsystem: subsystem, category: Category.replay.rawValue)
    private static let reflectionLogger = Logger(subsystem: subsystem, category: Category.reflection.rawValue)
    private static let materializeLogger = Logger(subsystem: subsystem, category: Category.materialize.rawValue)
    private static let reducerLogger = Logger(subsystem: subsystem, category: Category.reducer.rawValue)
    private static let adaptationLogger = Logger(subsystem: subsystem, category: Category.adaptation.rawValue)
    private static let propertyTestLogger = Logger(subsystem: subsystem, category: Category.propertyTest.rawValue)

    @inline(__always)
    private static func shouldLog(_ level: Level, category: Category, configuration: Configuration) -> Bool {
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
        level: Level,
        category: Category,
        event: String,
        message: String,
        metadata: [String: String],
        file: String,
        line: UInt,
        format: Format
    ) -> String {
        switch format {
        case .human:
            let metadataDescription = renderHumanMetadata(metadata)
            let messagePart = message.isEmpty ? "" : " \(message)"
            return "[\(category.rawValue)] [\(level)] [\(event)]\(messagePart)\(metadataDescription)"
        case .llmOptimized:
            let metadataDescription = renderLLMMetadata(metadata)
            return """
            {"kind":"exhaust_log","category":"\(escapeJSON(category.rawValue))","level":"\(level)","event":"\(escapeJSON(event))","message":"\(escapeJSON(message))","file":"\(escapeJSON(file))","line":\(line),"metadata":{\(metadataDescription)}}
            """
        }
    }

    private static func renderHumanMetadata(_ metadata: [String: String]) -> String {
        guard metadata.isEmpty == false else {
            return ""
        }
        let pairs = metadata
            .sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        return " \(pairs)"
    }

    private static func renderLLMMetadata(_ metadata: [String: String]) -> String {
        metadata
            .sorted(by: { $0.key < $1.key })
            .map { "\"\(escapeJSON($0.key))\":\"\(escapeJSON($0.value))\"" }
            .joined(separator: ",")
    }

    private static func escapeJSON(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.count)
        for character in value {
            switch character {
            case "\\":
                escaped += "\\\\"
            case "\"":
                escaped += "\\\""
            case "\n":
                escaped += "\\n"
            case "\r":
                escaped += "\\r"
            case "\t":
                escaped += "\\t"
            default:
                escaped.append(character)
            }
        }
        return escaped
    }
}
