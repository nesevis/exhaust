import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Expression macro that expands `#exhaust(gen, .settings...) { ... }` into a call to
/// `__ExhaustRuntime.__exhaust(...)` or `__ExhaustRuntime.__exhaustExpect(...)`.
///
/// The macro inspects the trailing closure to determine the runtime function:
/// - **Multi-statement closures** expand to `__exhaustExpect` (Void-returning, uses `withKnownIssue`).
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
    private static func closureIsVoidReturning(_ closure: ClosureExprSyntax) -> Bool {
        let statements = closure.statements

        if statements.count > 1 {
            return containsReturnWithValue(statements) == false
        }

        guard let onlyStatement = statements.first else { return true }

        let item = onlyStatement.item

        // Control flow statements are not value-returning expressions — Void path.
        if isControlFlowStatement(Syntax(item)) {
            return true
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
           let macroExpr = tryExpr.expression.as(MacroExpansionExprSyntax.self) {
            let name = macroExpr.macroName.text
            if name == "expect" || name == "require" {
                return true
            }
        }

        // Single expression that returns a value — Bool path.
        return false
    }

    /// Checks whether a syntax node represents a control flow statement (if, guard, for, while, do, switch).
    private static func isControlFlowStatement(_ node: Syntax) -> Bool {
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
    private static func containsReturnWithValue(_ statements: CodeBlockItemListSyntax) -> Bool {
        for statement in statements {
            // Direct return statement
            if let returnStmt = statement.item.as(ReturnStmtSyntax.self),
               returnStmt.expression != nil {
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
    private static func containsReturnWithValueRecursive(_ node: Syntax) -> Bool {
        for child in node.children(viewMode: .sourceAccurate) {
            if let returnStmt = child.as(ReturnStmtSyntax.self),
               returnStmt.expression != nil {
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
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")

    let closureText = trailingClosure.trimmedDescription
    let settingsArray = settingsExprs.isEmpty ? "[]" : "[\(settingsExprs.joined(separator: ", "))]"

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
        property: \(raw: closureText)
    )
    """
}

/// Expands the function-reference form of `#exhaust(gen, property: someFunc)`.
private func expandExhaustFunctionReference(
    of node: some FreestandingMacroExpansionSyntax,
    args: [LabeledExprListSyntax.Element],
    in context: some MacroExpansionContext
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
    __ExhaustRuntime.__exhaust(
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
