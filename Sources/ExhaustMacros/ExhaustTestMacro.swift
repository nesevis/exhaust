import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Expression macro that expands `#exhaust(gen, .settings...) { ... }` into a call to ``__ExhaustRuntime/__exhaust(...)`` or ``__ExhaustRuntime/__exhaustExpect(...)``.
///
/// The macro inspects the trailing closure to determine the runtime function:
/// - **Multi-statement closures** expand to `__exhaustExpect` (Void-returning, uses `withExpectedIssue`).
/// - **Single-expression closures containing `#expect` or `#require`** expand to `__exhaustExpect`.
/// - **All other single-expression closures** expand to `__exhaust` (Bool-returning predicate).
///
/// When a function reference is passed via `property:`, the expansion always uses `__exhaust`.
public struct ExhaustTestMacro: ExpressionMacro {
    public static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> ExprSyntax {
        let args = node.arguments.map(\.self)

        if let trailingClosure = node.trailingClosure {
            let runtimeFunction = closureIsVoidReturning(trailingClosure)
                ? "__exhaustExpect"
                : "__exhaust"
            return try expandExhaust(
                of: node,
                args: args,
                trailingClosure: trailingClosure,
                in: context,
                runtimeFunction: runtimeFunction
            )
        } else {
            return try expandExhaustFunctionReference(
                of: node,
                args: args,
                in: context
            )
        }
    }
}

// MARK: - Closure Analysis Helpers

/// Determines whether a trailing closure should use the Void assertion path.
///
/// Returns `true` (Void path) when the closure body cannot be a Bool-returning predicate:
/// - Multi-statement closures with no `return <value>`.
/// - Single statements that are control flow (`if`, `guard`, `for`, `while`, `do`, `switch`).
/// - Single statements that are `#expect` or `#require` macro invocations.
///
/// Returns `false` (Bool path) when the closure looks like a predicate:
/// - Single-expression closures (implicit return of a value).
/// - Multi-statement closures containing `return <value>`.
func closureIsVoidReturning(_ closure: ClosureExprSyntax) -> Bool {
    let statements = closure.statements

    if statements.count > 1 {
        return containsReturnWithValue(statements) == false
    }

    guard let onlyStatement = statements.first else { return true }

    let item = onlyStatement.item

    // Control flow statements that contain `return <value>` are Bool-returning (for example, a do/catch that returns true/false on each path).
    if isControlFlowStatement(Syntax(item)) {
        return containsReturnWithValueRecursive(Syntax(item)) == false
    }

    // #expect(...) or #require(...)
    if let macroExpr = item.as(MacroExpansionExprSyntax.self) {
        let name = macroExpr.macroName.text
        if name == "expect" || name == "require" {
            return true
        }
    }

    // try #require(...)
    if let tryExpr = item.as(TryExprSyntax.self),
       let macroExpr = tryExpr.expression.as(MacroExpansionExprSyntax.self)
    {
        let name = macroExpr.macroName.text
        if name == "expect" || name == "require" {
            return true
        }
    }

    // Single expression that returns a value — Bool path.
    return false
}

/// Checks whether a syntax node represents a control flow statement (if, guard, for, while, do, switch).
private func isControlFlowStatement(_ node: Syntax) -> Bool {
    node.is(IfExprSyntax.self)
        || node.is(GuardStmtSyntax.self)
        || node.is(ForStmtSyntax.self)
        || node.is(WhileStmtSyntax.self)
        || node.is(RepeatStmtSyntax.self)
        || node.is(DoStmtSyntax.self)
        || node.is(SwitchExprSyntax.self)
        || node.is(ThrowStmtSyntax.self)
        || node.as(ExpressionStmtSyntax.self).map { isControlFlowStatement(Syntax($0.expression)) } ?? false
}

/// Checks whether any statement in the closure body is a `return` with an expression value.
private func containsReturnWithValue(_ statements: CodeBlockItemListSyntax) -> Bool {
    for statement in statements {
        // Direct return statement
        if let returnStmt = statement.item.as(ReturnStmtSyntax.self),
           returnStmt.expression != nil
        {
            return true
        }

        // Return inside if/else, guard, switch, for, while, do/catch
        if containsReturnWithValueRecursive(Syntax(statement.item)) {
            return true
        }
    }
    return false
}

/// Recursively walks a syntax node looking for `return <value>` statements.
private func containsReturnWithValueRecursive(_ node: Syntax) -> Bool {
    for child in node.children(viewMode: .sourceAccurate) {
        if let returnStmt = child.as(ReturnStmtSyntax.self),
           returnStmt.expression != nil
        {
            return true
        }
        // Don't recurse into nested closures — their returns are their own
        if child.is(ClosureExprSyntax.self) {
            continue
        }
        if containsReturnWithValueRecursive(child) {
            return true
        }
    }
    return false
}

// MARK: - Detection Closure Rewriting

/// Rewrites `#expect` and `#require` calls in a closure body to use `__ExhaustRuntime.__detectRequire`.
///
/// This replaces Swift Testing assertion macros with plain throwing function calls that don't call `Issue.record()`, producing no test output during reduction. Both boolean checks and optional unwraps are handled:
///
/// - `#expect(condition)` → `try __ExhaustRuntime.__detectRequire(condition)`
/// - `try #require(condition)` → `try __ExhaustRuntime.__detectRequire(condition)`
/// - `let x = try #require(optional)` → `let x = try __ExhaustRuntime.__detectRequire(optional)`
///
/// Does not recurse into nested closures.
func rewriteExpectToRequire(_ closure: ClosureExprSyntax) -> ClosureExprSyntax {
    let rewriter = DetectionRewriter(viewMode: .sourceAccurate)
    return rewriter.rewrite(closure).cast(ClosureExprSyntax.self)
}

/// Rewrites `#expect`/`#require` calls in the property closure to include explicit `sourceLocation:` parameters.
///
/// In a macro expansion, `#_sourceLocation` resolves to the expansion site (the `#exhaust` line), not the original assertion line. This rewriter uses `MacroExpansionContext.location(of:)` to get each assertion's original source location and injects it as an explicit argument.
final class SourceLocationRewriter: SyntaxRewriter {
    let context: any MacroExpansionContext
    private var closureDepth = 0

    init(context: some MacroExpansionContext, viewMode: SyntaxTreeViewMode) {
        self.context = context
        super.init(viewMode: viewMode)
    }

    override func visit(_ node: ClosureExprSyntax) -> ExprSyntax {
        closureDepth += 1
        defer { closureDepth -= 1 }
        if closureDepth > 1 { return ExprSyntax(node) }
        return super.visit(node)
    }

    override func visit(_ node: MacroExpansionExprSyntax) -> ExprSyntax {
        guard node.macroName.text == "expect" || node.macroName.text == "require" else {
            return super.visit(node)
        }
        // Check if sourceLocation: is already specified
        let hasSourceLocation = node.arguments.contains { $0.label?.text == "sourceLocation" }
        if hasSourceLocation { return ExprSyntax(node) }

        guard let location = context.location(of: node, at: .afterLeadingTrivia, filePathMode: .filePath) else {
            // If location is unavailable, pass through unchanged.
            return ExprSyntax(node)
        }
        guard let fileIDLocation = context.location(of: node, at: .afterLeadingTrivia, filePathMode: .fileID) else {
            return ExprSyntax(node)
        }

        // Add sourceLocation: parameter with the original source location
        var arguments = node.arguments
        // Add trailing comma to the last existing argument
        if var lastArg = arguments.last {
            lastArg.trailingComma = .commaToken(trailingTrivia: .space)
            arguments = LabeledExprListSyntax(arguments.dropLast() + [lastArg])
        }
        let sourceLocationArg = LabeledExprSyntax(
            label: .identifier("sourceLocation"),
            colon: .colonToken(trailingTrivia: .space),
            expression: ExprSyntax(
                "Testing.SourceLocation(fileID: \(fileIDLocation.file), filePath: \(location.file), line: \(location.line), column: \(location.column))" as ExprSyntax
            )
        )
        arguments = arguments + [sourceLocationArg]

        return ExprSyntax(node.with(\.arguments, arguments))
    }
}

/// Replaces `#expect` and `#require` macro expansions with `__ExhaustRuntime.__detectRequire` calls.
/// Skips nested closures (depth > 0) since their assertions are their own.
private final class DetectionRewriter: SyntaxRewriter {
    private var closureDepth = 0

    override func visit(_ node: ClosureExprSyntax) -> ExprSyntax {
        closureDepth += 1
        defer { closureDepth -= 1 }
        if closureDepth > 1 {
            // Nested closure — don't rewrite its assertions.
            return ExprSyntax(node)
        }
        return super.visit(node)
    }

    override func visit(_ node: MacroExpansionExprSyntax) -> ExprSyntax {
        guard node.macroName.text == "expect" || node.macroName.text == "require" else {
            return super.visit(node)
        }
        guard let firstArg = node.arguments.first else {
            return ExprSyntax(node)
        }
        // Replace #expect/#require(args...) with __ExhaustRuntime.__detectRequire(firstArg)
        let call = FunctionCallExprSyntax(
            leadingTrivia: node.pound.leadingTrivia,
            calledExpression: MemberAccessExprSyntax(
                base: DeclReferenceExprSyntax(baseName: .identifier("__ExhaustRuntime")),
                period: .periodToken(),
                name: .identifier("__detectRequire")
            ),
            leftParen: .leftParenToken(),
            arguments: LabeledExprListSyntax([
                LabeledExprSyntax(expression: firstArg.expression.trimmed),
            ]),
            rightParen: .rightParenToken()
        )
        // If the original was #expect (not already inside a try), wrap in try.
        // If it was #require, it's already inside a TryExprSyntax — the parent handles try.
        if node.macroName.text == "expect" {
            return ExprSyntax(TryExprSyntax(
                tryKeyword: .keyword(.try, leadingTrivia: node.pound.leadingTrivia, trailingTrivia: .space),
                expression: ExprSyntax(call.with(\.leadingTrivia, []))
            ))
        }
        return ExprSyntax(call)
    }
}

// MARK: - Shared Expansion Logic

/// Expands the trailing-closure form of `#exhaust`.
private func expandExhaust(
    of node: some FreestandingMacroExpansionSyntax,
    args: [LabeledExprListSyntax.Element],
    trailingClosure: ClosureExprSyntax,
    in context: some MacroExpansionContext,
    runtimeFunction: String
) throws -> ExprSyntax {
    guard !args.isEmpty else {
        context.diagnose(Diagnostic(
            node: Syntax(node),
            message: ExhaustMacroDiagnostic.exhaustMissingGenerator
        ))
        return "fatalError(\"#exhaust requires a generator argument\")"
    }

    let generatorExpr = args[0].expression.trimmedDescription
    let settingsExprs = args.dropFirst().map(\.expression.trimmedDescription)

    let sourceCode = trailingClosure.statements.trimmedDescription
        .replacing("\\", with: "\\\\")
        .replacing("\"", with: "\\\"")
        .replacing("\n", with: "\\n")

    let settingsArray = settingsExprs.isEmpty ? "[]" : "[\(settingsExprs.joined(separator: ", "))]"

    if runtimeFunction == "__exhaustExpect" || runtimeFunction == "__exhaustExpectAsync" {
        // Void path: pass both the original closure (for final re-run with #expect)
        // and a detection closure (with #expect → __detectRequire, for pipeline via try/catch).
        //
        // Rewrite property closure to inject explicit sourceLocation: on each #expect/#require.
        // Without this, #_sourceLocation resolves to the #exhaust expansion site.
        let sourceLocationRewriter = SourceLocationRewriter(context: context, viewMode: .sourceAccurate)
        let propertyWithLocations = sourceLocationRewriter.rewrite(trailingClosure).cast(ClosureExprSyntax.self)

        // Detection closure: #expect/#require → __detectRequire (silent, no Issue.record).
        // Strip `async` — the detection closure is always synchronous.
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
            sourceCode: "\(raw: sourceCode)",
            fileID: #fileID,
            filePath: #filePath,
            line: #line,
            column: #column,
            function: #function,
            property: \(propertyWithLocations),
            detection: \(raw: detectionText)
        )
        """
    }

    return """
    __ExhaustRuntime.\(raw: runtimeFunction)(
        \(raw: generatorExpr),
        settings: \(raw: settingsArray),
        sourceCode: "\(raw: sourceCode)",
        fileID: #fileID,
        filePath: #filePath,
        line: #line,
        column: #column,
        function: #function,
        property: \(trailingClosure)
    )
    """
}

/// Expands the function-reference form of `#exhaust(gen, property: someFunc)`.
private func expandExhaustFunctionReference(
    of node: some FreestandingMacroExpansionSyntax,
    args: [LabeledExprListSyntax.Element],
    in context: some MacroExpansionContext,
    runtimeFunction: String = "__exhaust"
) throws -> ExprSyntax {
    guard args.count >= 2 else {
        context.diagnose(Diagnostic(
            node: Syntax(node),
            message: ExhaustMacroDiagnostic.exhaustMissingProperty
        ))
        return "fatalError(\"#exhaust requires a property argument\")"
    }

    let generatorExpr = args[0].expression.trimmedDescription

    guard let propertyArg = args.last, propertyArg.label?.text == "property" else {
        context.diagnose(Diagnostic(
            node: Syntax(node),
            message: ExhaustMacroDiagnostic.exhaustMissingProperty
        ))
        return "fatalError(\"#exhaust requires a property argument\")"
    }

    let propertyExpr = propertyArg.expression.trimmedDescription
    let settingsExprs = args.dropFirst().dropLast().map(\.expression.trimmedDescription)
    let settingsArray = settingsExprs.isEmpty ? "[]" : "[\(settingsExprs.joined(separator: ", "))]"

    return """
    __ExhaustRuntime.\(raw: runtimeFunction)(
        \(raw: generatorExpr),
        settings: \(raw: settingsArray),
        sourceCode: nil,
        fileID: #fileID,
        filePath: #filePath,
        line: #line,
        column: #column,
        function: #function,
        property: \(raw: propertyExpr)
    )
    """
}

// MARK: - Async Property Macro

/// Expression macro that expands `#exhaust(gen, .settings...) { value in await ... }` into a call to ``__ExhaustRuntime/__exhaustAsync(...)`` or ``__ExhaustRuntime/__exhaustExpectAsync(...)``.
///
/// Identical to ``ExhaustTestMacro`` but emits the async runtime variants. Swift's overload resolution routes here when the trailing closure's type is `(T) async throws -> R`.
public struct ExhaustAsyncTestMacro: ExpressionMacro {
    public static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> ExprSyntax {
        let args = node.arguments.map(\.self)

        if let trailingClosure = node.trailingClosure {
            let runtimeFunction = closureIsVoidReturning(trailingClosure)
                ? "__exhaustExpectAsync"
                : "__exhaustAsync"
            return try expandExhaust(
                of: node,
                args: args,
                trailingClosure: trailingClosure,
                in: context,
                runtimeFunction: runtimeFunction
            )
        } else {
            return try expandExhaustFunctionReference(
                of: node,
                args: args,
                in: context,
                runtimeFunction: "__exhaustAsync"
            )
        }
    }
}
