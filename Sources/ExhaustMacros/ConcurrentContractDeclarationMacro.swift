import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Attached macro that synthesizes ``ConcurrentContractSpec`` or ``AsyncConcurrentContractSpec`` conformance from a class annotated with `@ConcurrentContract`.
///
/// Reuses the shared extraction and synthesis helpers from ``ContractDeclarationMacro``. The additional requirements over `@Contract` are:
/// - The declaration must be a class (reference-type SUT for shared access across GCD threads).
/// - Exactly one `@Oracle` method is required.
/// - The macro synthesizes an `oracleCheck(_:)` method that delegates to the user's `@Oracle` method.
public struct ConcurrentContractDeclarationMacro: MemberMacro, ExtensionMacro {
    // MARK: - ExtensionMacro

    public static func expansion(
        of _: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo _: [TypeSyntax],
        in _: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        let members = declaration.memberBlock.members
        let commands = extractCommands(from: members)
        let invariants = extractInvariants(from: members)
        let oracles = extractOracles(from: members)
        // An async oracle forces the async protocol on its own: the synthesized `oracleCheck` must be able to `await` it, which only `AsyncConcurrentContractSpec` permits.
        let isActorDecl = declaration.is(ActorDeclSyntax.self)
        let hasAnyAsync =
            commands.contains(where: \.isAsync)
                || invariants.contains(where: \.isAsync)
                || oracles.contains(where: \.isAsync)
        let needsAsyncConformance = hasAnyAsync || isActorDecl

        let proto = needsAsyncConformance ? "AsyncConcurrentContractSpec" : "ConcurrentContractSpec"
        let preconcurrency = isActorDecl ? "@preconcurrency " : ""
        let ext: DeclSyntax = "extension \(type.trimmed): \(raw: preconcurrency)\(raw: proto) {}"
        return [ext.cast(ExtensionDeclSyntax.self)]
    }

    // MARK: - MemberMacro

    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo _: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        let members = declaration.memberBlock.members
        let isClassDecl = declaration.is(ClassDeclSyntax.self)
        let isActorDecl = declaration.is(ActorDeclSyntax.self)
        let isReferenceType = isClassDecl || isActorDecl

        if isReferenceType == false {
            context.diagnose(Diagnostic(
                node: Syntax(node),
                message: ConcurrentContractDiagnostic.mustBeClass
            ))
        }
        if isActorDecl {
            context.diagnose(Diagnostic(
                node: Syntax(node),
                message: ConcurrentContractDiagnostic.actorSerializesAccess
            ))
        }

        let modelProps = extractModelProperties(from: members)
        let sutProps = extractSUTProperties(from: members)
        let commands = extractCommands(from: members)
        let invariants = extractInvariants(from: members)
        let oracles = extractOracles(from: members)

        if commands.isEmpty {
            context.diagnose(Diagnostic(
                node: Syntax(node),
                message: ConcurrentContractDiagnostic.noCommands
            ))
        }
        if sutProps.isEmpty {
            context.diagnose(Diagnostic(
                node: Syntax(node),
                message: ConcurrentContractDiagnostic.noSUT
            ))
        }
        if sutProps.count > 1 {
            context.diagnose(Diagnostic(
                node: Syntax(node),
                message: ConcurrentContractDiagnostic.multipleSUT
            ))
        }
        if oracles.isEmpty {
            context.diagnose(Diagnostic(
                node: Syntax(node),
                message: ConcurrentContractDiagnostic.noOracle
            ))
        }
        if oracles.count > 1 {
            context.diagnose(Diagnostic(
                node: Syntax(node),
                message: ConcurrentContractDiagnostic.multipleOracles
            ))
        }

        let hasAnyAsync =
            commands.contains(where: \.isAsync)
                || invariants.contains(where: \.isAsync)
                || oracles.contains(where: \.isAsync)

        var decls: [DeclSyntax] = []

        decls.append(synthesizeCommandEnum(commands: commands))

        if let sutProp = sutProps.first, let sutType = sutProp.type {
            decls.append("typealias SystemUnderTest = \(raw: sutType)")
            decls.append("var systemUnderTest: SystemUnderTest { \(raw: sutProp.name) }")
        } else if sutProps.first != nil {
            context.diagnose(Diagnostic(
                node: Syntax(node),
                message: ConcurrentContractDiagnostic.sutTypeNotInferred
            ))
            decls.append("var systemUnderTest: Never { fatalError(\"SUT type could not be inferred — add an explicit type annotation to the @SystemUnderTest property\") }")
        }

        decls.append(synthesizeCommandGenerator(commands: commands, context: context))
        let effectiveAsync = hasAnyAsync || isActorDecl
        decls.append(synthesizeRunMethod(commands: commands, hasAnyAsync: effectiveAsync, isReferenceType: true))
        decls.append(synthesizeCheckInvariants(invariants: invariants, hasAnyAsync: effectiveAsync))
        decls.append(synthesizeModelDescription(modelProps: modelProps))
        decls.append(synthesizeSUTDescription(sutProps: sutProps))

        if let oracle = oracles.first {
            decls.append(synthesizeOracleCheck(oracle: oracle, hasAnyAsync: effectiveAsync))
        }

        let hasUserInit = members.contains { member in
            guard let initDecl = member.decl.as(InitializerDeclSyntax.self) else { return false }
            return initDecl.signature.parameterClause.parameters.isEmpty
        }
        if hasUserInit == false {
            if isClassDecl {
                decls.append("required init() {}")
            } else {
                decls.append("nonisolated init() {}")
            }
        }

        return decls
    }
}

// MARK: - Oracle Extraction

struct OracleInfo {
    let methodName: String
    let parameterLabel: String
    let parameterType: String
    let isAsync: Bool
}

func extractOracles(from members: MemberBlockItemListSyntax) -> [OracleInfo] {
    members.compactMap { member in
        guard let funcDecl = member.decl.as(FunctionDeclSyntax.self),
              hasAttribute("Oracle", on: funcDecl)
        else { return nil }
        let params = funcDecl.signature.parameterClause.parameters
        guard let firstParam = params.first else { return nil }
        let isAsync = funcDecl.signature.effectSpecifiers?.asyncSpecifier != nil
        return OracleInfo(
            methodName: funcDecl.name.trimmedDescription,
            parameterLabel: firstParam.firstName.trimmedDescription,
            parameterType: firstParam.type.trimmedDescription,
            isAsync: isAsync
        )
    }
}

// MARK: - Oracle Synthesis

func synthesizeOracleCheck(oracle: OracleInfo, hasAnyAsync: Bool) -> DeclSyntax {
    // The synthesized `oracleCheck` matches the protocol it satisfies: `AsyncConcurrentContractSpec` (when anything is async) requires an `async` method, so a synchronous oracle is simply called without `await` inside the async wrapper. `await` is emitted only for an async oracle.
    let signature = hasAnyAsync
        ? "func oracleCheck(_ sequentialResult: SystemUnderTest) async -> Bool"
        : "func oracleCheck(_ sequentialResult: SystemUnderTest) -> Bool"
    let awaitKeyword = oracle.isAsync ? "await " : ""
    // An unlabeled oracle parameter (`func check(_ result:)`) has firstName `_`, which is not a valid call label — omit the label entirely in that case.
    let callArgument = oracle.parameterLabel == "_"
        ? "sequentialResult"
        : "\(oracle.parameterLabel): sequentialResult"
    return """
    \(raw: signature) {
        \(raw: awaitKeyword)\(raw: oracle.methodName)(\(raw: callArgument))
    }
    """
}

// MARK: - Diagnostics

enum ConcurrentContractDiagnostic: String, DiagnosticMessage {
    case mustBeClass = "@ConcurrentContract must be applied to a reference type — use 'final class' instead of 'struct'"
    case actorSerializesAccess = "@ConcurrentContract on an actor has no effect. Actor isolation serializes all command dispatch, preventing the interleaving that concurrent testing requires. Use @Contract instead, or use a class if you need to test concurrent access to the underlying system."
    case noCommands = "@ConcurrentContract requires at least one @Command method"
    case noSUT = "@ConcurrentContract requires exactly one @SystemUnderTest property"
    case multipleSUT = "@ConcurrentContract requires exactly one @SystemUnderTest property, but multiple were found"
    case noOracle = "@ConcurrentContract requires exactly one @Oracle method"
    case multipleOracles = "@ConcurrentContract allows only one @Oracle method"
    case sutTypeNotInferred = "@SystemUnderTest property type could not be inferred — add an explicit type annotation"

    var message: String {
        rawValue
    }

    var diagnosticID: MessageID {
        MessageID(domain: "ExhaustMacros", id: "\(self)")
    }

    var severity: DiagnosticSeverity {
        switch self {
            case .mustBeClass, .noCommands, .noSUT, .multipleSUT, .noOracle, .multipleOracles: .error
            case .sutTypeNotInferred, .actorSerializesAccess: .warning
        }
    }
}
