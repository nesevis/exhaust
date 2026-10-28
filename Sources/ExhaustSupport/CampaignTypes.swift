import Foundation

/// Fixes the identity vocabulary independently of execution-model case descriptions.
package enum FuzzCampaignKind: String, Codable, Sendable {
    /// Searches generated values.
    case value
    /// Searches commands through the sequential adapter.
    case stateMachineSequential = "stateMachine.sequential"
    /// Searches a spec declared with cooperative task execution, including synchronous specs routed sequentially.
    case stateMachineTasks = "stateMachine.tasks"
}

/// Identifies the macro expansion without recording a machine-specific absolute path.
package struct CampaignSource: Codable, Sendable {
    package let fileID: String
    package let line: UInt
    package let column: UInt
    package init(fileID: String, line: UInt, column: UInt) {
        self.fileID = fileID
        self.line = line
        self.column = column
    }
}

/// Separates campaign completion from the property's outcome.
package enum CampaignStatus: String, Codable, Sendable {
    case running
    case completed
    case interrupted
}

/// Keeps invalid or unjudged experiments out of the passing count.
package enum CampaignOutcome: String, Codable, Sendable {
    case passed
    case failed
    case skipped
    case error
}
