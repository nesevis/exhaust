import ExhaustCore

/// Resolved suppression flags derived from one or more ``SuppressOption`` values.
///
/// Each mode's settings resolution constructs one of these and calls ``apply(_:)`` for every `.suppress` case it encounters. The `.all` expansion lives here once instead of in each resolver.
package struct SuppressFlags: Equatable, Sendable {
    package var issueReporting = false
    package var logs = false
    package var attachments = false

    package init() {}

    package mutating func apply(_ option: SuppressOption) {
        switch option {
            case .issueReporting:
                issueReporting = true
            case .logs:
                logs = true
            case .attachments:
                attachments = true
            case .all:
                issueReporting = true
                logs = true
                attachments = true
        }
    }

    /// Builds the log configuration implied by these flags.
    package func logConfiguration(minimumLevel: LogLevel, format: LogFormat = .keyValue) -> ExhaustLog.Configuration {
        ExhaustLog.Configuration(
            isEnabled: logs == false,
            minimumLevel: minimumLevel,
            format: format
        )
    }
}
