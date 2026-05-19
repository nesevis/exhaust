import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Expression macro that expands `#explore(gen, .settings..., directions: [...]) { ... }` into a call to `__ExhaustRuntime.__explore(...)` or `__ExhaustRuntime.__exploreExpect(...)`.
///
/// The macro inspects the trailing closure to determine the runtime function:
/// - **Multi-statement closures** expand to `__exploreExpect` (Void-returning, uses `withExpectedIssue`).
/// - **Single-expression closures containing `#expect` or `#require`** expand to `__exploreExpect`.
/// - **All other single-expression closures** expand to `__explore` (Bool-returning predicate).
///
/// When a function reference is passed via `property:`, the expansion always uses `__explore`.
public struct ExploreMacro: ExpressionMacro {
    public static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> ExprSyntax {
        let args = node.arguments.map(\.self)

        if let trailingClosure = node.trailingClosure {
            let runtimeFunction = closureIsVoidReturning(trailingClosure)
                ? "__exploreExpect"
                : "__explore"
            return try expandExplore(
                of: node,
                args: args,
                trailingClosure: trailingClosure,
                in: context,
                runtimeFunction: runtimeFunction
            )
        } else {
            return try expandExploreFunctionReference(of: node, args: args, in: context)
        }
    }
}

/// Expression macro for async `#explore` closures.
public struct ExploreAsyncMacro: ExpressionMacro {
    public static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> ExprSyntax {
        let args = node.arguments.map(\.self)

        if let trailingClosure = node.trailingClosure {
            let runtimeFunction = closureIsVoidReturning(trailingClosure)
                ? "__exploreExpectAsync"
                : "__exploreAsync"
            return try expandExplore(
                of: node,
                args: args,
                trailingClosure: trailingClosure,
                in: context,
                runtimeFunction: runtimeFunction
            )
        } else {
            return try expandExploreFunctionReference(
                of: node, args: args, in: context, runtimeFunction: "__exploreAsync"
            )
        }
    }
}

// MARK: - Shared Expansion Logic

private func expandExplore(
    of node: some FreestandingMacroExpansionSyntax,
    args: [LabeledExprListSyntax.Element],
    trailingClosure: ClosureExprSyntax,
    in context: some MacroExpansionContext,
    runtimeFunction: String
) throws -> ExprSyntax {
    guard !args.isEmpty else {
        context.diagnose(Diagnostic(
            node: Syntax(node),
            message: ExhaustMacroDiagnostic.exploreMissingGenerator
        ))
        return "fatalError(\"#explore requires a generator argument\")"
    }

    let generatorExpr = args[0].expression.trimmedDescription

    guard let directionsArg = args.first(where: { $0.label?.text == "directions" }) else {
        context.diagnose(Diagnostic(
            node: Syntax(node),
            message: ExhaustMacroDiagnostic.exploreMissingDirections
        ))
        return "fatalError(\"#explore requires a directions: argument\")"
    }

    let directionsExpr = directionsArg.expression.trimmedDescription
    let settingsExprs = args.dropFirst()
        .filter { $0.label?.text != "directions" }
        .map(\.expression.trimmedDescription)

    let sourceCode = trailingClosure.statements.trimmedDescription
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")

    let settingsArray = settingsExprs.isEmpty ? "[]" : "[\(settingsExprs.joined(separator: ", "))]"

    if runtimeFunction == "__exploreExpect" || runtimeFunction == "__exploreExpectAsync" {
        let sourceLocationRewriter = SourceLocationRewriter(context: context, viewMode: .sourceAccurate)
        let propertyWithLocations = sourceLocationRewriter.rewrite(trailingClosure).cast(ClosureExprSyntax.self)

        var detectionClosure = rewriteExpectToRequire(trailingClosure)
        if let sig = detectionClosure.signature,
           let effects = sig.effectSpecifiers,
           effects.asyncSpecifier != nil
        {
            let strippedEffects = effects.with(\.asyncSpecifier, nil)
            detectionClosure = detectionClosure.with(\.signature, sig.with(\.effectSpecifiers, strippedEffects))
        }
        let detectionText = detectionClosure.description

        return """
        __ExhaustRuntime.\(raw: runtimeFunction)(
            \(raw: generatorExpr),
            settings: \(raw: settingsArray),
            directions: \(raw: directionsExpr),
            sourceCode: "\(raw: sourceCode)",
            fileID: #fileID,
            filePath: #filePath,
            line: #line,
            column: #column,
            property: \(propertyWithLocations),
            detection: \(raw: detectionText)
        )
        """
    }

    let closureText = trailingClosure.trimmedDescription

    return """
    __ExhaustRuntime.\(raw: runtimeFunction)(
        \(raw: generatorExpr),
        settings: \(raw: settingsArray),
        directions: \(raw: directionsExpr),
        sourceCode: "\(raw: sourceCode)",
        fileID: #fileID,
        filePath: #filePath,
        line: #line,
        column: #column,
        property: \(raw: closureText)
    )
    """
}

private func expandExploreFunctionReference(
    of node: some FreestandingMacroExpansionSyntax,
    args: [LabeledExprListSyntax.Element],
    in context: some MacroExpansionContext,
    runtimeFunction: String = "__explore"
) throws -> ExprSyntax {
    guard args.count >= 3 else {
        context.diagnose(Diagnostic(
            node: Syntax(node),
            message: ExhaustMacroDiagnostic.exploreMissingProperty
        ))
        return "fatalError(\"#explore requires a property argument\")"
    }

    let generatorExpr = args[0].expression.trimmedDescription

    guard let propertyArg = args.last, propertyArg.label?.text == "property" else {
        context.diagnose(Diagnostic(
            node: Syntax(node),
            message: ExhaustMacroDiagnostic.exploreMissingProperty
        ))
        return "fatalError(\"#explore requires a property argument\")"
    }

    guard let directionsArg = args.first(where: { $0.label?.text == "directions" }) else {
        context.diagnose(Diagnostic(
            node: Syntax(node),
            message: ExhaustMacroDiagnostic.exploreMissingDirections
        ))
        return "fatalError(\"#explore requires a directions: argument\")"
    }

    let propertyExpr = propertyArg.expression.trimmedDescription
    let directionsExpr = directionsArg.expression.trimmedDescription
    let settingsExprs = args.dropFirst()
        .filter { $0.label?.text != "property" && $0.label?.text != "directions" }
        .map(\.expression.trimmedDescription)
    let settingsArray = settingsExprs.isEmpty ? "[]" : "[\(settingsExprs.joined(separator: ", "))]"

    return """
    __ExhaustRuntime.\(raw: runtimeFunction)(
        \(raw: generatorExpr),
        settings: \(raw: settingsArray),
        directions: \(raw: directionsExpr),
        sourceCode: nil,
        fileID: #fileID,
        filePath: #filePath,
        line: #line,
        column: #column,
        property: \(raw: propertyExpr)
    )
    """
}
