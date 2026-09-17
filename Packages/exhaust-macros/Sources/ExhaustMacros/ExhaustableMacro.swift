import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Emits generator metadata only after the declaration's construction strategy has been validated.
///
/// Both expansion roles use ``ExhaustableDeclaration``. Products require memberwise construction; the macro does not guess whether a user initializer preserves its arguments or whether an inheritance clause names a superclass. Unsupported forms produce one diagnostic from the extension role and no generated initializer from the member role.
public struct ExhaustableMacro: ExtensionMacro, MemberMacro {
    /// Emits the conformance from validated cases or stored properties, retaining the original annotation's source identity.
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo _: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        do {
            let model = try ExhaustableDeclaration.validate(declaration, lexicalContext: context.lexicalContext)
            guard let location = context.location(of: node, at: .afterLeadingTrivia, filePathMode: .fileID) else {
                throw ExhaustableDiagnostic.sourceLocationUnavailable
            }
            let typeName = type.trimmedDescription
            let valueType = specializedName(for: declaration, fallback: typeName)
            let caseEntries: [String] = switch model.construction {
                case let .enumeration(cases):
                    cases.map { caseEntry(for: $0, typeName: valueType) }
                case let .memberwise(properties), let .synthesizedMemberwise(properties):
                    [productEntry(properties: properties, typeName: typeName, valueType: valueType)]
            }
            let entries = caseEntries.joined(separator: ",\n            ")
            let limits = ["maximumDepth", "maximumNodes", "stateSpace"].compactMap { label in
                limitArgument(label, of: node).map { ", \(label): \($0)" }
            }.joined()
            let extensionDeclaration: DeclSyntax = """
            extension \(raw: typeName): __Exhaustable.Conformance {
                \(raw: model.access)static var __generatorDescriptor: __Exhaustable.TypeDescriptor<\(raw: valueType)> {
                    __Exhaustable.TypeDescriptor(constructors: [
                        \(raw: entries)
                    ]\(raw: limits), fileID: \(location.file), line: \(location.line), column: \(location.column))
                }
            }
            """
            guard let extensionSyntax = extensionDeclaration.as(ExtensionDeclSyntax.self) else {
                return []
            }
            return [extensionSyntax]
        } catch let diagnostic as ExhaustableDiagnostic {
            context.diagnose(Diagnostic(node: Syntax(node), message: diagnostic))
            return []
        }
    }

    /// Emits a final class's memberwise initializer only when the extension role can describe that same construction.
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo _: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let model = try? ExhaustableDeclaration.validate(declaration, lexicalContext: context.lexicalContext),
              case let .synthesizedMemberwise(properties) = model.construction,
              context.location(of: node, at: .afterLeadingTrivia, filePathMode: .fileID) != nil
        else {
            return []
        }
        let parameters = properties.map { property in
            let escaping = isFunctionType(property.type) ? "@escaping " : ""
            return "\(property.name): \(escaping)\(property.type.trimmedDescription)"
        }.joined(separator: ", ")
        let assignments = properties.map { "self.\($0.name) = \($0.name)" }.joined(separator: "\n    ")
        let initializer: DeclSyntax = """
        \(raw: model.access)init(\(raw: parameters)) {
            \(raw: assignments)
        }
        """
        return [initializer]
    }
}

// MARK: - Rendering

/// A nested generic name such as `Outer.Inner` is valid in the extension declaration but needs its own arguments in the descriptor and constructor expressions. Preserve qualification so unrelated types with the same short name cannot shadow it.
private func specializedName(for declaration: some DeclGroupSyntax, fallback: String) -> String {
    guard let parameters = declaration.asProtocol(WithGenericParametersSyntax.self)?.genericParameterClause else {
        return fallback
    }
    let arguments = parameters.parameters.map { $0.name.trimmedDescription }.joined(separator: ", ")
    return "\(fallback)<\(arguments)>"
}

/// Passes limit expressions through without evaluating them in the macro process.
private func limitArgument(_ label: String, of node: AttributeSyntax) -> String? {
    guard let arguments = node.arguments?.as(LabeledExprListSyntax.self) else {
        return nil
    }
    return arguments.first { $0.label?.text == label }?.expression.trimmedDescription
}

/// Uses only validated fields: every payload has a concrete type and a corresponding memberwise argument and extraction position.
private func productEntry(properties: [ExhaustableDeclaration.StoredProperty], typeName: String, valueType: String) -> String {
    let payloadTypes = properties.map { metatypeExpression($0.type) }
    let embedArguments = properties.enumerated().map { index, property in
        "\(property.name): values[\(index)] as! \(property.type.trimmedDescription)"
    }
    let embedBody = properties.isEmpty
        ? "{ _ in \(valueType)() }"
        : "{ values in \(valueType)(\(embedArguments.joined(separator: ", "))) }"
    let extractBody = "{ value in [\(properties.map { "value.\($0.name)" }.joined(separator: ", "))] }"
    return """
    __Exhaustable.ConstructorDescriptor(name: "\(typeName)", payloadTypes: [\(payloadTypes.joined(separator: ", "))], embed: \(embedBody), extract: \(extractBody))
    """
}

/// Preserves enum argument labels while using positional bindings to recover associated values.
private func caseEntry(for element: EnumCaseElementSyntax, typeName: String) -> String {
    let caseName = element.name.trimmedDescription
    let parameters = element.parameterClause?.parameters.map { $0 } ?? []
    let payloadTypes = parameters.map { metatypeExpression($0.type) }
    let embedArguments = parameters.enumerated().map { index, parameter in
        let label = parameter.firstName.flatMap { name in
            name.text == "_" ? nil : "\(name.trimmedDescription): "
        } ?? ""
        return "\(label)values[\(index)] as! \(parameter.type.trimmedDescription)"
    }
    let embedBody = parameters.isEmpty
        ? "{ _ in \(typeName).\(caseName) }"
        : "{ values in \(typeName).\(caseName)(\(embedArguments.joined(separator: ", "))) }"
    let bindings = parameters.indices.map { "value\($0)" }
    let extractPattern = parameters.isEmpty
        ? ".\(caseName)"
        : "let .\(caseName)(\(bindings.joined(separator: ", ")))"
    let extractBody = "{ value in if case \(extractPattern) = value { return [\(bindings.joined(separator: ", "))] } else { return nil } }"
    return """
    __Exhaustable.ConstructorDescriptor(name: "\(caseName)", payloadTypes: [\(payloadTypes.joined(separator: ", "))], embed: \(embedBody), extract: \(extractBody))
    """
}

private func metatypeExpression(_ type: TypeSyntax) -> String {
    let needsParentheses = isFunctionType(type) || type.is(SomeOrAnyTypeSyntax.self) || type.is(CompositionTypeSyntax.self)
    return needsParentheses ? "(\(type.trimmedDescription)).self" : "\(type.trimmedDescription).self"
}

/// Stored function parameters must escape when a synthesized class initializer assigns them to a property. Optional functions already escape without an annotation.
private func isFunctionType(_ type: TypeSyntax) -> Bool {
    if let attributed = type.as(AttributedTypeSyntax.self) {
        return isFunctionType(attributed.baseType)
    }
    if let tuple = type.as(TupleTypeSyntax.self), tuple.elements.count == 1, let element = tuple.elements.first {
        return isFunctionType(element.type)
    }
    return type.is(FunctionTypeSyntax.self)
}
