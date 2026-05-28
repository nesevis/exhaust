import SwiftSyntax
import SwiftSyntaxMacros

/// Expands `#gen(from: instance)` for `Codable` instances into a ``__ExhaustRuntime/_macroGenCodableInstance(_:)`` call that encodes the instance to JSON and synthesises a generator.
public struct GenerateFromCodableInstanceMacro: ExpressionMacro {
    public static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in _: some MacroExpansionContext
    ) throws -> ExprSyntax {
        let args = node.arguments.map(\.self)
        guard args.count == 1 else {
            return "fatalError(\"#gen(instance) requires exactly one argument\")"
        }

        let instanceExpr = args[0].expression.trimmedDescription

        return "try __ExhaustRuntime._macroGenCodableInstance(\(raw: instanceExpr))"
    }
}
