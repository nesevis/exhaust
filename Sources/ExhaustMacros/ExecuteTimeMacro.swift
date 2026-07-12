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
        __ExhaustRuntime.__runStateMachineTimeDispatch(
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
}
