import SwiftSyntax
import SwiftSyntaxMacros

/// Marker macro for model state properties. Generates no code — `@StateMachine` reads this annotation.
public struct ModelMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext,
    ) throws -> [DeclSyntax] {
        []
    }
}

/// Marker macro for the system under test property. Generates no code — `@StateMachine` reads this annotation.
public struct SUTMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext,
    ) throws -> [DeclSyntax] {
        []
    }
}

/// Marker macro for command methods. Generates no code — `@StateMachine` reads this annotation.
public struct CommandMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext,
    ) throws -> [DeclSyntax] {
        []
    }
}

/// Marker macro for invariant methods. Generates no code — `@StateMachine` reads this annotation.
public struct InvariantMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext,
    ) throws -> [DeclSyntax] {
        []
    }
}
