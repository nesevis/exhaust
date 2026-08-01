import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Expands `#explore(Spec.self, mode: .tasks, time: .minutes(5), .settings...)` into a call to `__ExhaustRuntime.__runStateMachineTimeDispatch(...)`.
public struct ExploreSpecTimeMacro: ExpressionMacro {
    public static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> ExprSyntax {
        expandExploreSpecTimeCall(of: node, in: context, dispatchFunction: "__runStateMachineTimeDispatch")
    }
}

/// Expands `#explore(AsyncSpec.self, mode: .sequential, time: .minutes(5), .settings...)` into a call to `__ExhaustRuntime.__runStateMachineTimeDispatchAsync(...)`.
public struct ExploreSpecTimeAsyncMacro: ExpressionMacro {
    public static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> ExprSyntax {
        expandExploreSpecTimeCall(of: node, in: context, dispatchFunction: "__runStateMachineTimeDispatchAsync")
    }
}

// MARK: - Shared Expansion Logic

/// The shared body of the sync and async time-budgeted spec macros: validates the spec and `time:` arguments and expands. The two macros differ only in the runtime dispatch function name.
private func expandExploreSpecTimeCall(
    of node: some FreestandingMacroExpansionSyntax,
    in context: some MacroExpansionContext,
    dispatchFunction: String
) -> ExprSyntax {
    let arguments = Array(node.arguments)

    context.diagnose(Diagnostic(
        node: Syntax(node),
        message: ExhaustMacroDiagnostic.exploreTimeExperimental
    ))

    guard arguments.count >= 1 else {
        context.diagnose(Diagnostic(
            node: Syntax(node),
            message: ExhaustMacroDiagnostic.exploreStateMachineMissingSpec
        ))
        return "fatalError(\"#explore requires a spec type argument\")"
    }

    let specExpression = arguments[0].expression.trimmedDescription

    guard let timeArgument = arguments.first(where: { $0.label?.text == "time" }) else {
        context.diagnose(Diagnostic(
            node: Syntax(node),
            message: ExhaustMacroDiagnostic.exploreTimeMissingTime
        ))
        return "fatalError(\"#explore(time:) requires a 'time:' argument\")"
    }
    let timeExpression = timeArgument.expression.trimmedDescription

    guard let modeExpression = executionModeExpression(from: arguments) else {
        context.diagnose(Diagnostic(
            node: Syntax(node),
            message: ExhaustMacroDiagnostic.exploreStateMachineMissingMode
        ))
        return "fatalError(\"#explore requires a 'mode:' argument\")"
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
