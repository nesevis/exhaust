import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Expression macro that expands `#execute(Contract.self, .settings...)` into a call to `__ExhaustRuntime.__runContractDispatch(...)` for synchronous contract property tests.
public struct ExhaustContractMacro: ExpressionMacro {
    public static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> ExprSyntax {
        try expandExecuteCall(node: node, context: context, dispatchFunction: "__runContractDispatch")
    }
}

/// Expression macro that expands `#execute(AsyncContract.self, .settings...)` into a call to `__ExhaustRuntime.__runContractDispatchAsync(...)` for asynchronous contract property tests.
public struct ExhaustAsyncContractMacro: ExpressionMacro {
    public static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> ExprSyntax {
        try expandExecuteCall(node: node, context: context, dispatchFunction: "__runContractDispatchAsync")
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
            message: ExhaustMacroDiagnostic.exhaustContractMissingSpec
        ))
        return "fatalError(\"#execute requires a spec type argument\")"
    }

    let specExpr = args[0].expression.trimmedDescription
    let settingsExprs = args.dropFirst(1).map(\.expression.trimmedDescription)
    let settingsArray = settingsExprs.isEmpty ? "[]" : "[\(settingsExprs.joined(separator: ", "))]"

    return """
    __ExhaustRuntime.\(raw: dispatchFunction)(
        \(raw: specExpr),
        settings: \(raw: settingsArray),
        fileID: #fileID,
        filePath: #filePath,
        line: #line,
        column: #column
    )
    """
}
