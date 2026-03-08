import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Expression macro that expands `#explore(gen, .settings..., scorer: scoreFn) { ... }` or `#explore(gen, .settings..., scorer: scoreFn, property: someFunc)` into a call to `__ExhaustRuntime.__explore(...)`.
///
/// When a trailing closure is used, the closure body source code is captured for log output. When a function reference is passed, `sourceCode` is `nil`.
public struct ExploreMacro: ExpressionMacro {
    public static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext,
    ) throws -> ExprSyntax {
        let args = node.arguments.map(\.self)

        if let trailingClosure = node.trailingClosure {
            // Trailing closure path — capture source code
            // Args: gen, settings..., scorer: scoreFn
            guard !args.isEmpty else {
                context.diagnose(Diagnostic(
                    node: Syntax(node),
                    message: ExhaustMacroDiagnostic.exploreMissingGenerator,
                ))
                return "fatalError(\"#explore requires a generator argument\")"
            }

            let generatorExpr = args[0].expression.trimmedDescription

            // Find the scorer: labeled argument
            guard let scorerArg = args.first(where: { $0.label?.text == "scorer" }) else {
                context.diagnose(Diagnostic(
                    node: Syntax(node),
                    message: ExhaustMacroDiagnostic.exploreMissingScorer,
                ))
                return "fatalError(\"#explore requires a scorer: argument\")"
            }

            let scorerExpr = scorerArg.expression.trimmedDescription
            let settingsExprs = args.dropFirst()
                .filter { $0.label?.text != "scorer" }
                .map(\.expression.trimmedDescription)

            let sourceCode = trailingClosure.statements.trimmedDescription
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")

            let closureText = trailingClosure.trimmedDescription
            let settingsArray = settingsExprs.isEmpty ? "[]" : "[\(settingsExprs.joined(separator: ", "))]"

            return """
            __ExhaustRuntime.__explore(
                \(raw: generatorExpr),
                settings: \(raw: settingsArray),
                scorer: \(raw: scorerExpr),
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
            guard args.count >= 3 else {
                context.diagnose(Diagnostic(
                    node: Syntax(node),
                    message: ExhaustMacroDiagnostic.exploreMissingProperty,
                ))
                return "fatalError(\"#explore requires a property argument\")"
            }

            let generatorExpr = args[0].expression.trimmedDescription

            // Find the property: labeled argument
            guard let propertyArg = args.last, propertyArg.label?.text == "property" else {
                context.diagnose(Diagnostic(
                    node: Syntax(node),
                    message: ExhaustMacroDiagnostic.exploreMissingProperty,
                ))
                return "fatalError(\"#explore requires a property argument\")"
            }

            // Find the scorer: labeled argument
            guard let scorerArg = args.first(where: { $0.label?.text == "scorer" }) else {
                context.diagnose(Diagnostic(
                    node: Syntax(node),
                    message: ExhaustMacroDiagnostic.exploreMissingScorer,
                ))
                return "fatalError(\"#explore requires a scorer: argument\")"
            }

            let propertyExpr = propertyArg.expression.trimmedDescription
            let scorerExpr = scorerArg.expression.trimmedDescription
            let settingsExprs = args.dropFirst()
                .filter { $0.label?.text != "property" && $0.label?.text != "scorer" }
                .map(\.expression.trimmedDescription)
            let settingsArray = settingsExprs.isEmpty ? "[]" : "[\(settingsExprs.joined(separator: ", "))]"

            return """
            __ExhaustRuntime.__explore(
                \(raw: generatorExpr),
                settings: \(raw: settingsArray),
                scorer: \(raw: scorerExpr),
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
