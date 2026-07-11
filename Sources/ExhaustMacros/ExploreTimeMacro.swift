import Foundation
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Expression macro that expands `#explore(gen, time: .minutes(15), .settings...) { ... }` into a call to `__ExhaustRuntime.__exploreTime(...)` or `__ExhaustRuntime.__exploreTimeExpect(...)`.
///
/// The macro inspects the trailing closure to determine the runtime function:
/// - **Multi-statement closures** expand to `__exploreTimeExpect` (Void-returning, uses `withExpectedIssue`).
/// - **Single-expression closures containing `#expect` or `#require`** expand to `__exploreTimeExpect`.
/// - **All other single-expression closures** expand to `__exploreTime` (Bool-returning predicate).
///
/// When a function reference is passed via `property:`, the expansion always uses `__exploreTime`.
///
/// The `time:` and `directions:` modes are mutually exclusive at the type level; a call carrying both arguments is diagnosed here for a clearer message than overload-resolution failure.
public struct ExploreTimeMacro: ExpressionMacro {
    public static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> ExprSyntax {
        try expandExploreTimeCall(
            of: node,
            in: context,
            plainFunction: "__exploreTime",
            expectFunction: "__exploreTimeExpect"
        )
    }
}

/// Expression macro for async `#explore(time:)` closures.
public struct ExploreTimeAsyncMacro: ExpressionMacro {
    public static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> ExprSyntax {
        try expandExploreTimeCall(
            of: node,
            in: context,
            plainFunction: "__exploreTimeAsync",
            expectFunction: "__exploreTimeExpectAsync"
        )
    }
}

// MARK: - Shared Expansion Logic

/// The shared body of the sync and async `time:` macros: diagnoses the closure, picks the plain or expect runtime function, and expands. The two macros differ only in the runtime function names.
private func expandExploreTimeCall(
    of node: some FreestandingMacroExpansionSyntax,
    in context: some MacroExpansionContext,
    plainFunction: String,
    expectFunction: String
) throws -> ExprSyntax {
    let args = node.arguments.map(\.self)

    // Emitted on every expansion until the mode stabilizes: SwiftPM suppresses dependency warnings, so a library-side #warning would never reach a consumer, while a macro diagnostic lands in the user's own build at the call site.
    context.diagnose(Diagnostic(
        node: Syntax(node),
        message: ExhaustMacroDiagnostic.exploreTimeExperimental
    ))

    guard let trailingClosure = node.trailingClosure else {
        return try expandExploreTimeFunctionReference(
            of: node, args: args, in: context, runtimeFunction: plainFunction
        )
    }

    let isVoid = closureIsVoidReturning(trailingClosure)
    if isVoid, voidClosureLacksFailureMechanism(trailingClosure) {
        let diagnostic: ExhaustMacroDiagnostic = enclosingFunctionHasTestAttribute(context)
            ? .closureCannotFail
            : .closureCannotFailXCTest
        context.diagnose(Diagnostic(
            node: Syntax(trailingClosure),
            message: diagnostic
        ))
    }
    for site in xcTestCallSites(trailingClosure) {
        let diagnostic: ExhaustMacroDiagnostic = switch site.kind {
            case .unwrap: .xcTestUnwrapInPropertyClosure
            case .assert: .xcTestAssertInPropertyClosure
        }
        context.diagnose(Diagnostic(node: site.node, message: diagnostic))
    }
    return try expandExploreTime(
        of: node,
        args: args,
        trailingClosure: trailingClosure,
        in: context,
        runtimeFunction: isVoid ? expectFunction : plainFunction,
        isExpectExpansion: isVoid
    )
}

private func expandExploreTime(
    of node: some FreestandingMacroExpansionSyntax,
    args: [LabeledExprListSyntax.Element],
    trailingClosure: ClosureExprSyntax,
    in context: some MacroExpansionContext,
    runtimeFunction: String,
    isExpectExpansion: Bool
) throws -> ExprSyntax {
    guard args.isEmpty == false else {
        context.diagnose(Diagnostic(
            node: Syntax(node),
            message: ExhaustMacroDiagnostic.exploreMissingGenerator
        ))
        return "fatalError(\"#explore requires a generator argument\")"
    }

    let generatorExpr = args[0].expression.trimmedDescription

    guard let timeExpr = validatedTimeArgument(of: node, args: args, in: context) else {
        return "fatalError(\"#explore(time:) requires a 'time:' argument\")"
    }

    let settingsExprs = args.dropFirst()
        .filter { $0.label?.text != "time" }
        .map(\.expression.trimmedDescription)

    let settingsArray = settingsExprs.isEmpty ? "[]" : "[\(settingsExprs.joined(separator: ", "))]"

    if isExpectExpansion {
        let sourceLocationRewriter = SourceLocationRewriter(context: context, viewMode: .sourceAccurate)
        let propertyWithLocations = sourceLocationRewriter.rewrite(trailingClosure).cast(ClosureExprSyntax.self)

        var detectionClosure = rewriteExpectToRequire(trailingClosure)
        if let signature = detectionClosure.signature,
           let effects = signature.effectSpecifiers,
           effects.asyncSpecifier != nil
        {
            let strippedEffects = effects.with(\.asyncSpecifier, nil)
            detectionClosure = detectionClosure.with(\.signature, signature.with(\.effectSpecifiers, strippedEffects))
        }
        let detectionText = detectionClosure.description

        return """
        __ExhaustRuntime.\(raw: runtimeFunction)(
            \(raw: generatorExpr),
            time: \(raw: timeExpr),
            settings: \(raw: settingsArray),
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
        time: \(raw: timeExpr),
        settings: \(raw: settingsArray),
        fileID: #fileID,
        filePath: #filePath,
        line: #line,
        column: #column,
        property: \(raw: closureText)
    )
    """
}

private func expandExploreTimeFunctionReference(
    of node: some FreestandingMacroExpansionSyntax,
    args: [LabeledExprListSyntax.Element],
    in context: some MacroExpansionContext,
    runtimeFunction: String = "__exploreTime"
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

    guard let timeExpr = validatedTimeArgument(of: node, args: args, in: context) else {
        return "fatalError(\"#explore(time:) requires a 'time:' argument\")"
    }

    let propertyExpr = propertyArg.expression.trimmedDescription
    let settingsExprs = args.dropFirst()
        .filter { $0.label?.text != "property" && $0.label?.text != "time" }
        .map(\.expression.trimmedDescription)
    let settingsArray = settingsExprs.isEmpty ? "[]" : "[\(settingsExprs.joined(separator: ", "))]"

    return """
    __ExhaustRuntime.\(raw: runtimeFunction)(
        \(raw: generatorExpr),
        time: \(raw: timeExpr),
        settings: \(raw: settingsArray),
        fileID: #fileID,
        filePath: #filePath,
        line: #line,
        column: #column,
        property: \(raw: propertyExpr)
    )
    """
}

/// Extracts the `time:` argument, diagnosing a missing `time:` and the type-level-impossible-but-clearer-here combination with `directions:`. Returns nil when expansion should bail.
private func validatedTimeArgument(
    of node: some FreestandingMacroExpansionSyntax,
    args: [LabeledExprListSyntax.Element],
    in context: some MacroExpansionContext
) -> String? {
    if let directionsArg = args.first(where: { $0.label?.text == "directions" }) {
        context.diagnose(Diagnostic(
            node: Syntax(directionsArg.expression),
            message: ExhaustMacroDiagnostic.exploreTimeWithDirections
        ))
        return nil
    }
    guard let timeArg = args.first(where: { $0.label?.text == "time" }) else {
        context.diagnose(Diagnostic(
            node: Syntax(node),
            message: ExhaustMacroDiagnostic.exploreTimeMissingTime
        ))
        return nil
    }
    return timeArg.expression.trimmedDescription
}
