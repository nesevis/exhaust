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
    let modeExpr = executionModeExpression(from: args)
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

/// The `mode:` argument as written, or the default when the call site omits it.
///
/// Forwarded verbatim rather than resolved to a case, so a mode computed at runtime reaches the dispatch unchanged. The literal spelling is only read for the diagnostics that can be answered at expansion time; see ``executionModeLiteral(from:)``.
func executionModeExpression(from arguments: [LabeledExprSyntax]) -> String {
    arguments.first { $0.label?.text == "mode" }?.expression.trimmedDescription ?? ".sequential"
}

/// The mode's case name when the call site wrote a literal one, or nil when it omitted the argument or computed the value.
///
/// A computed mode is not knowable here, so the checks that depend on which mode a run uses fall back to the runtime ones. That is why those checks exist in both places.
func executionModeLiteral(from arguments: [LabeledExprSyntax]) -> String? {
    guard let modeArgument = arguments.first(where: { $0.label?.text == "mode" }),
          let memberAccess = modeArgument.expression.as(MemberAccessExprSyntax.self)
    else {
        return nil
    }
    return memberAccess.declName.baseName.trimmedDescription
}
