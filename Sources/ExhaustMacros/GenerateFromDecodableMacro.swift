import SwiftSyntax
import SwiftSyntaxMacros

/// Expands `#gen(T.self, from: data)` into a ``__ExhaustRuntime/_macroGenDecodable(_:from:)`` call that synthesises a generator from a `Decodable` type and example JSON.
public struct GenerateFromDecodableMacro: ExpressionMacro {
    public static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in _: some MacroExpansionContext
    ) throws -> ExprSyntax {
        let args = node.arguments.map(\.self)
        guard args.count == 2 else {
            return "fatalError(\"#gen(T.self, from:) requires exactly two arguments\")"
        }

        let typeExpr = args[0].expression.trimmedDescription
        let dataExpr = args[1].expression.trimmedDescription

        return "try __ExhaustRuntime._macroGenDecodable(\(raw: typeExpr), from: \(raw: dataExpr))"
    }
}
