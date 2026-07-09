import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

/// Marker macro for the system under test property. Generates no code — `@StateMachine` reads this annotation.
public struct SUTMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        if declaration.is(VariableDeclSyntax.self) == false {
            context.diagnose(Diagnostic(
                node: Syntax(node),
                message: MarkerDiagnostic.sutRequiresProperty
            ))
        }
        return []
    }
}

/// Marker macro for command methods. Generates no code — `@StateMachine` reads this annotation.
public struct CommandMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        if declaration.is(FunctionDeclSyntax.self) == false {
            context.diagnose(Diagnostic(
                node: Syntax(node),
                message: MarkerDiagnostic.commandRequiresMethod
            ))
        }
        return []
    }
}

/// Marker macro for invariant methods. Generates no code — `@StateMachine` reads this annotation.
public struct InvariantMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        if declaration.is(FunctionDeclSyntax.self) == false {
            context.diagnose(Diagnostic(
                node: Syntax(node),
                message: MarkerDiagnostic.invariantRequiresMethod
            ))
        }
        return []
    }
}

/// Marker macro for oracle comparison methods. Generates no code — `@StateMachine(.threads)` reads this annotation.
public struct OracleMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        if declaration.is(FunctionDeclSyntax.self) == false {
            context.diagnose(Diagnostic(
                node: Syntax(node),
                message: MarkerDiagnostic.oracleRequiresMethod
            ))
        }
        return []
    }
}

// MARK: - Diagnostics

private enum MarkerDiagnostic: String, DiagnosticMessage {
    case sutRequiresProperty = "@SystemUnderTest must be applied to a stored property"
    case commandRequiresMethod = "@Command must be applied to a method"
    case invariantRequiresMethod = "@Invariant must be applied to a method"
    case oracleRequiresMethod = "@Oracle must be applied to a method"

    var message: String {
        rawValue
    }

    var diagnosticID: MessageID {
        MessageID(domain: "ExhaustMacros", id: "\(self)")
    }

    var severity: DiagnosticSeverity {
        .error
    }
}
