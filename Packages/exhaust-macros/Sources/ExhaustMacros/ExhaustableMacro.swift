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
            let declarationName = declarationName(for: declaration)
            let settings = node.arguments?.as(LabeledExprListSyntax.self)?.map { $0.expression.trimmedDescription } ?? []
            let renderedSettings = settings.isEmpty ? "" : ", settings: [\(settings.joined(separator: ", "))]"
            let trailing = renderedSettings
                + ", fileID: \(location.file.trimmedDescription)"
                + ", line: \(location.line.trimmedDescription)"
                + ", column: \(location.column.trimmedDescription)"
            let entries: [(text: String, availability: ExhaustableDeclaration.CaseAvailability)] = switch model.construction {
                case let .enumeration(cases):
                    cases.compactMap { entry in
                        guard case .never = entry.availability else {
                            return (
                                caseEntry(
                                    for: entry.element,
                                    valueType: valueType,
                                    declarationName: declarationName,
                                    qualifiedTypeName: typeName,
                                    specializedTypeName: valueType
                                ),
                                entry.availability
                            )
                        }
                        return nil
                    }
                case let .memberwise(properties), let .synthesizedMemberwise(properties, _):
                    [(
                        productEntry(
                            properties: properties,
                            typeName: typeName,
                            valueType: valueType,
                            declarationName: declarationName,
                            qualifiedTypeName: typeName,
                            specializedTypeName: valueType
                        ),
                        .always
                    )]
            }
            let extensionDeclaration = conformanceExtension(
                typeName: typeName,
                valueType: valueType,
                access: model.access,
                entries: entries,
                trailing: trailing
            )
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
    ///
    /// The initializer is `nonisolated` so a global-actor-isolated class can still be constructed on the thread that draws a value. Payloads that genuinely need the actor make this initializer fail to compile, which is where the isolation error belongs.
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo _: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let model = try? ExhaustableDeclaration.validate(declaration, lexicalContext: context.lexicalContext),
              case let .synthesizedMemberwise(properties, initializerAccess) = model.construction,
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
        \(raw: initializerAccess)nonisolated init(\(raw: parameters)) {
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

/// Returns the declaration's unqualified name after validation has restricted it to a supported nominal type.
private func declarationName(for declaration: some DeclGroupSyntax) -> String {
    declaration.as(EnumDeclSyntax.self)?.name.text
        ?? declaration.as(StructDeclSyntax.self)?.name.text
        ?? declaration.as(ClassDeclSyntax.self)?.name.text
        ?? ""
}

/// Uses only validated fields: every payload has a concrete type and a corresponding memberwise argument and extraction position.
private func productEntry(
    properties: [ExhaustableDeclaration.StoredProperty],
    typeName: String,
    valueType: String,
    declarationName: String,
    qualifiedTypeName: String,
    specializedTypeName: String
) -> String {
    let qualifiedProperties = properties.map {
        (
            name: $0.name,
            type: qualifySelfReferences(
                in: $0.type,
                declarationName: declarationName,
                qualifiedTypeName: qualifiedTypeName,
                specializedTypeName: specializedTypeName
            )
        )
    }
    let payloadTypes = qualifiedProperties.map { metatypeExpression($0.type) }
    let embedArguments = qualifiedProperties.enumerated().map { index, property in
        "\(property.name): values[\(index)] as! \(property.type.trimmedDescription)"
    }
    let embedBody = properties.isEmpty
        ? "{ _ in \(valueType)() }"
        : "{ values in \(valueType)(\(embedArguments.joined(separator: ", "))) }"
    // Each element is cast explicitly: an Optional field coerced into `[Any]` warns, which fails a build using -warnings-as-errors. `as Any` keeps a `.none` boxed for `embed` to cast back.
    let extractBody = "{ value in [\(properties.map { "value.\($0.name) as Any" }.joined(separator: ", "))] }"
    return constructorEntry(name: typeName, payloadTypes: payloadTypes, embedBody: embedBody, extractBody: extractBody)
}

/// Builds the conformance extension, keeping the descriptor's constructors in a plain array whenever every entry is namable in every build.
///
/// A version-gated case cannot sit in an array literal, because that expression is evaluated wherever the property is read. Those entries are appended inside `#available` instead, which makes the constructor list depend on the running system: a case introduced in a later release contributes no constructor on an older one, so nothing references a case the compiler would reject there.
private func conformanceExtension(
    typeName: String,
    valueType: String,
    access: String,
    entries: [(text: String, availability: ExhaustableDeclaration.CaseAvailability)],
    trailing: String
) -> DeclSyntax {
    guard entries.contains(where: { entry in
        guard case .guarded = entry.availability else {
            return false
        }
        return true
    }) else {
        let literal = entries.map(\.text).joined(separator: ",\n")
        return """
        extension \(raw: typeName): nonisolated __Exhaustable.Conformance {
            \(raw: access)nonisolated static var __generatorDescriptor: __Exhaustable.TypeDescriptor<\(raw: valueType)> {
                __Exhaustable.TypeDescriptor(constructors: [
                    \(raw: literal)
                ]\(raw: trailing))
            }
        }
        """
    }
    let statements = entries.map { entry in
        switch entry.availability {
            case .always, .never:
                "constructors.append(\(entry.text))"
            case let .guarded(versions):
                """
                if #available(\(versions.joined(separator: ", ")), *) {
                    constructors.append(\(entry.text))
                }
                """
        }
    }.joined(separator: "\n")
    return """
    extension \(raw: typeName): nonisolated __Exhaustable.Conformance {
        \(raw: access)nonisolated static var __generatorDescriptor: __Exhaustable.TypeDescriptor<\(raw: valueType)> {
            var constructors: [__Exhaustable.ConstructorDescriptor<\(raw: valueType)>] = []
            \(raw: statements)
            return __Exhaustable.TypeDescriptor(constructors: constructors\(raw: trailing))
        }
    }
    """
}

/// Preserves enum argument labels while using positional bindings to recover associated values.
private func caseEntry(
    for element: EnumCaseElementSyntax,
    valueType: String,
    declarationName: String,
    qualifiedTypeName: String,
    specializedTypeName: String
) -> String {
    let caseName = element.name.trimmedDescription
    let parameters = element.parameterClause?.parameters.map { parameter in
        (
            label: parameter.firstName,
            type: qualifySelfReferences(
                in: parameter.type,
                declarationName: declarationName,
                qualifiedTypeName: qualifiedTypeName,
                specializedTypeName: specializedTypeName
            )
        )
    } ?? []
    let payloadTypes = parameters.map { metatypeExpression($0.type) }
    let embedArguments = parameters.enumerated().map { index, parameter in
        let label = parameter.label.flatMap { name in
            name.text == "_" ? nil : "\(name.trimmedDescription): "
        } ?? ""
        return "\(label)values[\(index)] as! \(parameter.type.trimmedDescription)"
    }
    let embedBody = parameters.isEmpty
        ? "{ _ in \(valueType).\(caseName) }"
        : "{ values in \(valueType).\(caseName)(\(embedArguments.joined(separator: ", "))) }"
    let bindings = parameters.indices.map { "value\($0)" }
    let extractPattern = parameters.isEmpty
        ? ".\(caseName)"
        : "let .\(caseName)(\(bindings.joined(separator: ", ")))"
    let extracted = bindings.map { "\($0) as Any" }.joined(separator: ", ")
    let extractBody = "{ value in if case \(extractPattern) = value { return [\(extracted)] } else { return nil } }"
    return constructorEntry(name: caseName, payloadTypes: payloadTypes, embedBody: embedBody, extractBody: extractBody)
}

/// Keeps product and enum constructor metadata in the same generated shape; their embedding and extraction expressions are the only structural differences.
private func constructorEntry(name: String, payloadTypes: [String], embedBody: String, extractBody: String) -> String {
    """
    __Exhaustable.ConstructorDescriptor(name: "\(name)", payloadTypes: [\(payloadTypes.joined(separator: ", "))], embed: \(embedBody), extract: \(extractBody))
    """
}

private func metatypeExpression(_ type: TypeSyntax) -> String {
    let needsParentheses = isFunctionType(type) || type.is(SomeOrAnyTypeSyntax.self) || type.is(CompositionTypeSyntax.self)
    return needsParentheses ? "(\(type.trimmedDescription)).self" : "\(type.trimmedDescription).self"
}

/// Qualifies shorthand self references because a peer extension does not inherit the nested declaration's lexical scope.
private func qualifySelfReferences(
    in type: TypeSyntax,
    declarationName: String,
    qualifiedTypeName: String,
    specializedTypeName: String
) -> TypeSyntax {
    SelfTypeQualifier(
        declarationName: declarationName,
        qualifiedTypeName: qualifiedTypeName,
        specializedTypeName: specializedTypeName
    ).visit(type)
}

/// Rewrites the annotated type's shorthand name wherever it appears inside a payload type, including standard containers and changed generic specializations.
private final class SelfTypeQualifier: SyntaxRewriter {
    private let declarationName: String
    private let qualifiedTypeName: String
    private let specializedTypeName: String

    init(
        declarationName: String,
        qualifiedTypeName: String,
        specializedTypeName: String
    ) {
        self.declarationName = declarationName
        self.qualifiedTypeName = qualifiedTypeName
        self.specializedTypeName = specializedTypeName
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: IdentifierTypeSyntax) -> TypeSyntax {
        let rewritten = super.visit(node)
        guard node.name.text == declarationName,
              let identifier = rewritten.as(IdentifierTypeSyntax.self)
        else {
            return rewritten
        }
        guard let arguments = identifier.genericArgumentClause?.trimmedDescription else {
            return TypeSyntax(stringLiteral: specializedTypeName)
        }
        return TypeSyntax(stringLiteral: "\(qualifiedTypeName)\(arguments)")
    }
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
