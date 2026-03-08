import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Expression macro that expands `#exhaust(gen, .settings...) { ... }` or `#exhaust(gen, .settings..., property: someFunc)` into a call to `__ExhaustRuntime.__exhaust(...)`.
///
/// When a trailing closure is used, the closure body source code is captured for log output. When a function reference is passed, `sourceCode` is `nil`.
public struct ExhaustTestMacro: ExpressionMacro {
    public static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext,
    ) throws -> ExprSyntax {
        let args = node.arguments.map(\.self)

        if let trailingClosure = node.trailingClosure {
            // Trailing closure path — capture source code
            guard !args.isEmpty else {
                context.diagnose(Diagnostic(
                    node: Syntax(node),
                    message: ExhaustMacroDiagnostic.exhaustMissingGenerator,
                ))
                return "fatalError(\"#exhaust requires a generator argument\")"
            }

            let generatorExpr = args[0].expression.trimmedDescription
            let settingsExprs = args.dropFirst().map(\.expression.trimmedDescription)

            let sourceCode = trailingClosure.statements.trimmedDescription
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")

            let closureText = trailingClosure.trimmedDescription
            let settingsArray = settingsExprs.isEmpty ? "[]" : "[\(settingsExprs.joined(separator: ", "))]"

            return """
            __ExhaustRuntime.__exhaust(
                \(raw: generatorExpr),
                settings: \(raw: settingsArray),
                sourceCode: "\(raw: sourceCode)",
                fileID: #fileID,
                filePath: #filePath,
                line: #line,
                column: #column,
                property: \(raw: closureText)
            )
            """
        } else {
            // No trailing closure — property is the last labeled argument
            guard args.count >= 2 else {
                context.diagnose(Diagnostic(
                    node: Syntax(node),
                    message: ExhaustMacroDiagnostic.exhaustMissingProperty,
                ))
                return "fatalError(\"#exhaust requires a property argument\")"
            }

            let generatorExpr = args[0].expression.trimmedDescription

            // Find the property: labeled argument
            guard let propertyArg = args.last, propertyArg.label?.text == "property" else {
                context.diagnose(Diagnostic(
                    node: Syntax(node),
                    message: ExhaustMacroDiagnostic.exhaustMissingProperty,
                ))
                return "fatalError(\"#exhaust requires a property argument\")"
            }

            let propertyExpr = propertyArg.expression.trimmedDescription
            let settingsExprs = args.dropFirst().dropLast().map(\.expression.trimmedDescription)
            let settingsArray = settingsExprs.isEmpty ? "[]" : "[\(settingsExprs.joined(separator: ", "))]"

            return """
            __ExhaustRuntime.__exhaust(
                \(raw: generatorExpr),
                settings: \(raw: settingsArray),
                sourceCode: nil,
                fileID: #fileID,
                filePath: #filePath,
                line: #line,
                column: #column,
                property: \(raw: propertyExpr)
            )
            """
        }
    }
}
