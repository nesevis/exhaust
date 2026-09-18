import SwiftDiagnostics
import SwiftSyntax

/// Validates the construction strategy before either macro role emits code. The extension role owns diagnostics; the member role uses the same validation but emits nothing on failure.
struct ExhaustableDeclaration {
    enum Construction {
        case enumeration([EnumCaseElementSyntax])
        case memberwise([StoredProperty])
        case synthesizedMemberwise([StoredProperty])
    }

    /// Retains only the validated name and type used by constructor rendering. Storage and initializer restrictions are checked before creating the model.
    struct StoredProperty {
        let name: String
        let type: TypeSyntax
    }

    let access: String
    let construction: Construction

    /// Rejects forms whose construction cannot be established from the declaration alone, rather than guessing at initializer signatures or superclass requirements.
    static func validate(
        _ declaration: some DeclGroupSyntax,
        lexicalContext: [Syntax]
    ) throws -> Self {
        guard hasParameterPacks(Syntax(declaration)) == false,
              lexicalContext.contains(where: hasParameterPacks) == false
        else {
            throw ExhaustableDiagnostic.parameterPacksUnsupported
        }
        guard declaration.memberBlock.members.contains(where: { $0.decl.is(IfConfigDeclSyntax.self) }) == false else {
            throw ExhaustableDiagnostic.conditionalMembersUnsupported
        }
        if let enumeration = declaration.as(EnumDeclSyntax.self) {
            let cases = enumeration.memberBlock.members.flatMap { member -> [EnumCaseElementSyntax] in
                guard let entry = member.decl.as(EnumCaseDeclSyntax.self) else {
                    return []
                }
                return Array(entry.elements)
            }
            return Self(
                access: accessPrefix(for: enumeration.modifiers, lexicalContext: lexicalContext),
                construction: .enumeration(cases)
            )
        }
        if let structure = declaration.as(StructDeclSyntax.self) {
            return try Self(
                access: accessPrefix(for: structure.modifiers, lexicalContext: lexicalContext),
                construction: .memberwise(productProperties(
                    in: structure.memberBlock.members,
                    allowingDirectInitializer: true
                ))
            )
        }
        if let classDeclaration = declaration.as(ClassDeclSyntax.self) {
            guard classDeclaration.modifiers.contains(where: { $0.name.tokenKind == .keyword(.final) }) else {
                throw ExhaustableDiagnostic.classMustBeFinal
            }
            // Syntax alone cannot distinguish a superclass from a protocol or a type alias. Protocol conformances can be moved to extensions.
            guard classDeclaration.inheritanceClause == nil else {
                throw ExhaustableDiagnostic.classInheritanceUnsupported
            }
            return try Self(
                access: accessPrefix(for: classDeclaration.modifiers, lexicalContext: lexicalContext),
                construction: .synthesizedMemberwise(productProperties(in: classDeclaration.memberBlock.members))
            )
        }
        throw ExhaustableDiagnostic.requiresEnumStructOrFinalClass
    }

    /// Allows only products whose stored fields can be passed directly to a memberwise initializer and recovered unchanged by extraction.
    private static func productProperties(
        in members: MemberBlockItemListSyntax,
        allowingDirectInitializer: Bool = false
    ) throws -> [StoredProperty] {
        let initializers = members.compactMap { $0.decl.as(InitializerDeclSyntax.self) }
        var properties: [StoredProperty] = []
        for member in members {
            guard let variable = member.decl.as(VariableDeclSyntax.self),
                  variable.modifiers.contains(where: { $0.name.text == "static" || $0.name.text == "class" }) == false
            else {
                continue
            }
            for binding in variable.bindings where isStored(binding) {
                guard variable.attributes.isEmpty else {
                    throw ExhaustableDiagnostic.propertyAttributesUnsupported
                }
                guard variable.modifiers.contains(where: { ["lazy", "weak", "unowned"].contains($0.name.text) }) == false else {
                    throw ExhaustableDiagnostic.propertyStorageUnsupported
                }
                guard let identifier = binding.pattern.as(IdentifierPatternSyntax.self) else {
                    throw ExhaustableDiagnostic.propertyPatternUnsupported
                }
                guard let type = binding.typeAnnotation?.type else {
                    throw ExhaustableDiagnostic.propertyNeedsTypeAnnotation
                }
                guard variable.bindingSpecifier.tokenKind == .keyword(.var) || binding.initializer == nil else {
                    throw ExhaustableDiagnostic.initializedConstantUnsupported
                }
                properties.append(StoredProperty(name: identifier.identifier.trimmedDescription, type: type))
            }
        }
        guard initializers.isEmpty || (
            allowingDirectInitializer && initializers.count == 1
                && initializers.allSatisfy { isDirectMemberwise($0, properties: properties) }
        ) else {
            throw ExhaustableDiagnostic.customInitializerUnsupported
        }
        return properties
    }

    /// Accepts only the same field order, labels, types, and assignments as synthesized memberwise construction. Transformations, overloads, effects, defaults, and extra statements remain unsupported.
    private static func isDirectMemberwise(
        _ initializer: InitializerDeclSyntax,
        properties: [StoredProperty]
    ) -> Bool {
        let parameters = initializer.signature.parameterClause.parameters
        guard initializer.optionalMark == nil,
              initializer.genericParameterClause == nil,
              initializer.genericWhereClause == nil,
              initializer.signature.effectSpecifiers == nil,
              initializer.attributes.isEmpty,
              let statements = initializer.body?.statements,
              parameters.count == properties.count,
              statements.count == properties.count
        else {
            return false
        }
        for (property, parameter) in zip(properties, parameters) {
            guard parameter.firstName.text == property.name,
                  parameter.secondName == nil,
                  parameter.attributes.isEmpty,
                  parameter.modifiers.isEmpty,
                  parameter.defaultValue == nil,
                  parameter.ellipsis == nil,
                  parameter.type.trimmedDescription == property.type.trimmedDescription
            else {
                return false
            }
        }
        for (property, statement) in zip(properties, statements) {
            guard statement.item.tokens(viewMode: .sourceAccurate).map(\.text)
                == ["self", ".", property.name, "=", property.name]
            else {
                return false
            }
        }
        return true
    }

    private static func isStored(_ binding: PatternBindingSyntax) -> Bool {
        guard let accessors = binding.accessorBlock else {
            return true
        }
        switch accessors.accessors {
            case .getter:
                return false
            case let .accessors(list):
                return list.allSatisfy { accessor in
                    accessor.accessorSpecifier.tokenKind == .keyword(.willSet)
                        || accessor.accessorSpecifier.tokenKind == .keyword(.didSet)
                }
        }
    }

    private static func hasParameterPacks(_ declaration: Syntax) -> Bool {
        let parameters = declaration.as(EnumDeclSyntax.self)?.genericParameterClause
            ?? declaration.as(StructDeclSyntax.self)?.genericParameterClause
            ?? declaration.as(ClassDeclSyntax.self)?.genericParameterClause
            ?? declaration.as(ActorDeclSyntax.self)?.genericParameterClause
        return parameters?.parameters.contains { $0.eachKeyword != nil } ?? false
    }

    /// Uses the effective enclosing access so an extension on a nested private type does not expose that type through an internal descriptor property.
    private static func accessPrefix(for modifiers: DeclModifierListSyntax, lexicalContext: [Syntax]) -> String {
        let enclosing = lexicalContext.compactMap { declaration in
            declaration.as(EnumDeclSyntax.self)?.modifiers
                ?? declaration.as(StructDeclSyntax.self)?.modifiers
                ?? declaration.as(ClassDeclSyntax.self)?.modifiers
                ?? declaration.as(ActorDeclSyntax.self)?.modifiers
        }
        let access = ([modifiers] + enclosing).map(accessLevel).min() ?? .moduleScope
        return access.prefix
    }

    private static func accessLevel(_ modifiers: DeclModifierListSyntax) -> AccessLevel {
        let names = modifiers.map(\.name.text)
        if names.contains("private") || names.contains("fileprivate") {
            return .fileScope
        }
        if names.contains("package") {
            return .packageScope
        }
        if names.contains("public") || names.contains("open") {
            return .publicScope
        }
        return .moduleScope
    }

    /// Orders effective visibility so a nested declaration cannot expose its enclosing type. Private declarations need a fileprivate witness because the expansion lives in a separate extension.
    private enum AccessLevel: Int, Comparable {
        case fileScope
        case moduleScope
        case packageScope
        case publicScope

        var prefix: String {
            switch self {
                case .fileScope:
                    "fileprivate "
                case .moduleScope:
                    ""
                case .packageScope:
                    "package "
                case .publicScope:
                    "public "
            }
        }

        static func < (left: Self, right: Self) -> Bool {
            left.rawValue < right.rawValue
        }
    }
}

/// Gives unsupported declarations one deliberate diagnostic instead of errors in partially generated members and extensions.
enum ExhaustableDiagnostic: String, Error, DiagnosticMessage {
    case requiresEnumStructOrFinalClass
    case classMustBeFinal
    case parameterPacksUnsupported
    case propertyNeedsTypeAnnotation
    case sourceLocationUnavailable
    case initializedConstantUnsupported
    case customInitializerUnsupported
    case classInheritanceUnsupported
    case propertyAttributesUnsupported
    case propertyStorageUnsupported
    case propertyPatternUnsupported
    case conditionalMembersUnsupported

    var message: String {
        switch self {
            case .requiresEnumStructOrFinalClass:
                "@Exhaustable can only be attached to an enum, a struct, or a final class"
            case .classMustBeFinal:
                "@Exhaustable requires a class to be final"
            case .parameterPacksUnsupported:
                "@Exhaustable does not support generic parameter packs or types nested in declarations with parameter packs"
            case .propertyNeedsTypeAnnotation:
                "@Exhaustable needs a type annotation on every stored property"
            case .sourceLocationUnavailable:
                "@Exhaustable requires a source location to identify its derived generator family"
            case .initializedConstantUnsupported:
                "@Exhaustable does not support initialized let properties; write a generator for this type instead"
            case .customInitializerUnsupported:
                "@Exhaustable requires memberwise construction without in-body initializers; move struct initializers to an extension or write a generator for this type instead"
            case .classInheritanceUnsupported:
                "@Exhaustable requires a final class without an inheritance clause; put protocol conformances in extensions"
            case .propertyAttributesUnsupported:
                "@Exhaustable does not support attributes or property wrappers on stored properties; remove the attribute or write a generator for this type instead"
            case .propertyStorageUnsupported:
                "@Exhaustable does not support lazy, weak, or unowned stored properties; use plain storage or write a generator for this type instead"
            case .propertyPatternUnsupported:
                "@Exhaustable does not support tuple destructuring in a stored property; declare each property on its own"
            case .conditionalMembersUnsupported:
                "@Exhaustable does not support conditional compilation in the declaration's members; move the #if outside the type so each variant is its own annotated declaration"
        }
    }

    var diagnosticID: MessageID {
        MessageID(domain: "ExhaustMacros", id: rawValue)
    }

    var severity: DiagnosticSeverity {
        .error
    }
}
