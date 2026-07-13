import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Expands `#execute(Spec.self, time: .minutes(5), .settings...)` into a call to `__ExhaustRuntime.__runStateMachineTimeDispatch(...)`.
public struct ExecuteTimeMacro: ExpressionMacro {
    public static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> ExprSyntax {
        expandExecuteTimeCall(of: node, in: context, dispatchFunction: "__runStateMachineTimeDispatch")
    }
}

/// Expands `#execute(AsyncSpec.self, time: .minutes(5), .settings...)` into a call to `__ExhaustRuntime.__runStateMachineTimeDispatchAsync(...)`.
public struct ExecuteTimeAsyncMacro: ExpressionMacro {
    public static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> ExprSyntax {
        expandExecuteTimeCall(of: node, in: context, dispatchFunction: "__runStateMachineTimeDispatchAsync")
    }
}

// MARK: - Shared Expansion Logic

/// The shared body of the sync and async `#execute(time:)` macros: validates the spec and `time:` arguments and expands. The two macros differ only in the runtime dispatch function name.
private func expandExecuteTimeCall(
    of node: some FreestandingMacroExpansionSyntax,
    in context: some MacroExpansionContext,
    dispatchFunction: String
) -> ExprSyntax {
    let arguments = Array(node.arguments)

    context.diagnose(Diagnostic(
        node: Syntax(node),
        message: ExhaustMacroDiagnostic.executeTimeExperimental
    ))

    guard arguments.count >= 1 else {
        context.diagnose(Diagnostic(
            node: Syntax(node),
            message: ExhaustMacroDiagnostic.exhaustStateMachineMissingSpec
        ))
        return "fatalError(\"#execute requires a spec type argument\")"
    }

    let specExpression = arguments[0].expression.trimmedDescription

    guard let timeArgument = arguments.first(where: { $0.label?.text == "time" }) else {
        context.diagnose(Diagnostic(
            node: Syntax(node),
            message: ExhaustMacroDiagnostic.executeTimeMissingTime
        ))
        return "fatalError(\"#execute(time:) requires a 'time:' argument\")"
    }
    let timeExpression = timeArgument.expression.trimmedDescription

    let settingsExpressions = arguments.dropFirst()
        .filter { $0.label?.text != "time" }
        .map(\.expression.trimmedDescription)
    let settingsArray = settingsExpressions.isEmpty ? "[]" : "[\(settingsExpressions.joined(separator: ", "))]"

    return """
    __ExhaustRuntime.\(raw: dispatchFunction)(
        \(raw: specExpression),
        time: \(raw: timeExpression),
        settings: \(raw: settingsArray),
        fileID: #fileID,
        filePath: #filePath,
        line: #line,
        column: #column
    )
    """
}
