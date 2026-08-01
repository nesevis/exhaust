import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Expression macro that expands `#execute(StateMachine.self, mode:, .settings...)` into a call to `__ExhaustRuntime.__runStateMachineDispatch(...)` for synchronous spec tests.
public struct ExhaustStateMachineMacro: ExpressionMacro {
    public static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> ExprSyntax {
        try expandExecuteCall(node: node, context: context, dispatchFunction: "__runStateMachineDispatch")
    }
}

/// Expression macro that expands `#execute(AsyncStateMachine.self, mode:, .settings...)` into a call to `__ExhaustRuntime.__runStateMachineDispatchAsync(...)` for asynchronous spec tests.
public struct ExhaustAsyncStateMachineMacro: ExpressionMacro {
    public static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> ExprSyntax {
        try expandExecuteCall(node: node, context: context, dispatchFunction: "__runStateMachineDispatchAsync")
    }
}

// MARK: - Shared Expansion

private func expandExecuteCall(
    node: some FreestandingMacroExpansionSyntax,
    context: some MacroExpansionContext,
    dispatchFunction: String
) throws -> ExprSyntax {
    let args = Array(node.arguments)

    guard args.count >= 1 else {
        context.diagnose(Diagnostic(
            node: Syntax(node),
            message: ExhaustMacroDiagnostic.exhaustStateMachineMissingSpec
        ))
        return "fatalError(\"#execute requires a spec type argument\")"
    }

    let specExpr = args[0].expression.trimmedDescription
    guard let modeExpr = executionModeExpression(from: args) else {
        context.diagnose(Diagnostic(
            node: Syntax(node),
            message: ExhaustMacroDiagnostic.exhaustStateMachineMissingMode
        ))
        return "fatalError(\"#execute requires a 'mode:' argument\")"
    }
    let settingsExprs = args.dropFirst(1)
        .filter { $0.label?.text != "mode" }
        .map(\.expression.trimmedDescription)
    let settingsArray = settingsExprs.isEmpty ? "[]" : "[\(settingsExprs.joined(separator: ", "))]"

    return """
    __ExhaustRuntime.\(raw: dispatchFunction)(
        \(raw: specExpr),
        mode: \(raw: modeExpr),
        settings: \(raw: settingsArray),
        fileID: #fileID,
        filePath: #filePath,
        line: #line,
        column: #column
    )
    """
}

// MARK: - Mode Argument

/// The `mode:` argument as written, or nil when the call site omitted it.
///
/// Forwarded verbatim rather than resolved to a case, so a mode computed at runtime reaches the dispatch unchanged. Nothing here reads which mode it names: what a mode requires of a spec is checked at the start of the run, where a computed mode is knowable too.
///
/// There is no default to fall back on. Every `#execute` overload declares `mode:`, so a call reaching expansion without one has already failed overload resolution; the nil case exists so that failure reports as a named diagnostic rather than expanding into a silently sequential run.
func executionModeExpression(from arguments: [LabeledExprSyntax]) -> String? {
    arguments.first { $0.label?.text == "mode" }?.expression.trimmedDescription
}
