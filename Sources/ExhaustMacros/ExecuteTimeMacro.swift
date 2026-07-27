import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Expands `#execute(Spec.self, mode: .tasks, time: .minutes(5), .settings...)`, and the `#explore` spelling of the same call, into a call to `__ExhaustRuntime.__runStateMachineTimeDispatch(...)`.
public struct ExecuteTimeMacro: ExpressionMacro {
    public static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> ExprSyntax {
        expandExecuteTimeCall(of: node, in: context, dispatchFunction: "__runStateMachineTimeDispatch")
    }
}

/// Expands `#execute(AsyncSpec.self, mode: .sequential, time: .minutes(5), .settings...)`, and the `#explore` spelling of the same call, into a call to `__ExhaustRuntime.__runStateMachineTimeDispatchAsync(...)`.
public struct ExecuteTimeAsyncMacro: ExpressionMacro {
    public static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> ExprSyntax {
        expandExecuteTimeCall(of: node, in: context, dispatchFunction: "__runStateMachineTimeDispatchAsync")
    }
}

// MARK: - Call-Site Spelling

// The same two macro implementations back `#execute(Spec.self, mode:, time:)` and `#explore(Spec.self, mode:, time:)`. A fixed diagnostic string would name the other macro on half of its call sites, so every message and every expansion fallback reads the spelling off the expansion node.

/// Which macro a time-budgeted spec call was written as.
private enum TimeSearchSpelling {
    case execute
    case explore

    init(callSite node: some FreestandingMacroExpansionSyntax) {
        self = switch node.macroName.text {
            case "explore":
                .explore
            default:
                .execute
        }
    }

    /// The macro name as written, for interpolating into expansion fallbacks.
    var name: String {
        switch self {
            case .execute: "#execute"
            case .explore: "#explore"
        }
    }

    var experimental: ExhaustMacroDiagnostic {
        switch self {
            case .execute: .executeTimeExperimental
            case .explore: .exploreTimeExperimental
        }
    }

    var missingSpec: ExhaustMacroDiagnostic {
        switch self {
            case .execute: .exhaustStateMachineMissingSpec
            case .explore: .exploreStateMachineMissingSpec
        }
    }

    var missingTime: ExhaustMacroDiagnostic {
        switch self {
            case .execute: .executeTimeMissingTime
            case .explore: .exploreTimeMissingTime
        }
    }

    var missingMode: ExhaustMacroDiagnostic {
        switch self {
            case .execute: .exhaustStateMachineMissingMode
            case .explore: .exploreStateMachineMissingMode
        }
    }
}

// MARK: - Shared Expansion Logic

/// The shared body of the sync and async time-budgeted spec macros: validates the spec and `time:` arguments and expands. The two macros differ only in the runtime dispatch function name.
private func expandExecuteTimeCall(
    of node: some FreestandingMacroExpansionSyntax,
    in context: some MacroExpansionContext,
    dispatchFunction: String
) -> ExprSyntax {
    let arguments = Array(node.arguments)
    let spelling = TimeSearchSpelling(callSite: node)

    context.diagnose(Diagnostic(
        node: Syntax(node),
        message: spelling.experimental
    ))

    guard arguments.count >= 1 else {
        context.diagnose(Diagnostic(
            node: Syntax(node),
            message: spelling.missingSpec
        ))
        return "fatalError(\"\(raw: spelling.name) requires a spec type argument\")"
    }

    let specExpression = arguments[0].expression.trimmedDescription

    guard let timeArgument = arguments.first(where: { $0.label?.text == "time" }) else {
        context.diagnose(Diagnostic(
            node: Syntax(node),
            message: spelling.missingTime
        ))
        return "fatalError(\"\(raw: spelling.name)(time:) requires a 'time:' argument\")"
    }
    let timeExpression = timeArgument.expression.trimmedDescription

    guard let modeExpression = executionModeExpression(from: arguments) else {
        context.diagnose(Diagnostic(
            node: Syntax(node),
            message: spelling.missingMode
        ))
        return "fatalError(\"\(raw: spelling.name) requires a 'mode:' argument\")"
    }

    let settingsExpressions = arguments.dropFirst()
        .filter { $0.label?.text != "time" && $0.label?.text != "mode" }
        .map(\.expression.trimmedDescription)
    let settingsArray = settingsExpressions.isEmpty ? "[]" : "[\(settingsExpressions.joined(separator: ", "))]"

    return """
    __ExhaustRuntime.\(raw: dispatchFunction)(
        \(raw: specExpression),
        mode: \(raw: modeExpression),
        time: \(raw: timeExpression),
        settings: \(raw: settingsArray),
        fileID: #fileID,
        filePath: #filePath,
        line: #line,
        column: #column
    )
    """
}
