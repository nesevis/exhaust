import SwiftDiagnostics
import SwiftSyntax

/// Validates the construction strategy before either macro role emits code. The extension role owns diagnostics; the member role uses the same validation but emits nothing on failure.
struct ExhaustableDeclaration {
    enum Construction {
        case enumeration([EnumCase])
        case memberwise([StoredProperty])

        /// Carries its own access because a generated initializer may not be more visible than the payload types it names, and a `private` payload admits no other level. The descriptor witness cannot borrow that level: it lives in an extension, where `private` would scope it to the extension alone.
        case synthesizedMemberwise([StoredProperty], initializerAccess: String)
    }

    /// Retains only the validated name and type used by constructor rendering. Storage and initializer restrictions are checked before creating the model.
    struct StoredProperty {
        let name: String
        let type: TypeSyntax
    }

    /// Pairs a case element with the availability of the `case` declaration that introduced it. The element alone does not carry those attributes, and one declaration can introduce several elements that all share them.
    struct EnumCase {
        let element: EnumCaseElementSyntax
        let availability: CaseAvailability
    }

    /// Decides how a case reaches the descriptor: written plainly, written inside a version check, or left out because no build can name it.
    enum CaseAvailability {
        case always

        /// Platform-version specifications for an `#available` check, without the trailing wildcard.
        case guarded([String])

        case never
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
            let cases = try enumeration.memberBlock.members.flatMap { member -> [EnumCase] in
                guard let entry = member.decl.as(EnumCaseDeclSyntax.self) else {
                    return []
                }
                let availability = try caseAvailability(of: entry.attributes)
                return entry.elements.map { EnumCase(element: $0, availability: availability) }
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
                ).properties)
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
            let stored = try productProperties(in: classDeclaration.memberBlock.members)
            let declared = accessLevel(for: classDeclaration.modifiers, lexicalContext: lexicalContext)
            return Self(
                access: max(declared, .fileScope).prefix,
                construction: .synthesizedMemberwise(
                    stored.properties,
                    initializerAccess: min(max(declared, .fileScope), stored.access).prefix
                )
            )
        }
        throw ExhaustableDiagnostic.requiresEnumStructOrFinalClass
    }

    /// Reads a case declaration's availability so the renderer can reference the case only where the compiler accepts it.
    ///
    /// An introduced version becomes an `#available` check. A case that no build can name contributes no constructor at all, because generating one would require an expression that never type-checks. Deprecation, renaming, and messages leave constructibility alone and are ignored.
    private static func caseAvailability(of attributes: AttributeListSyntax) throws -> CaseAvailability {
        var versions: [String] = []
        for element in attributes {
            guard let attribute = element.as(AttributeSyntax.self),
                  attribute.attributeName.trimmedDescription == "available",
                  case let .availability(arguments) = attribute.arguments
            else {
                continue
            }
            var platform: String?
            var isWildcard = false
            for argument in arguments {
                switch argument.argument {
                    case let .token(token):
                        switch token.text {
                            case "*":
                                isWildcard = true
                            case "unavailable":
                                // A platform-specific `unavailable` leaves the case namable in other builds, which no single check expresses.
                                guard isWildcard || platform == nil else {
                                    throw ExhaustableDiagnostic.caseAvailabilityUnsupported
                                }
                                return .never
                            case "deprecated", "noasync":
                                break
                            default:
                                platform = token.text
                        }
                    case let .availabilityVersionRestriction(restriction):
                        guard isRuntimePlatform(restriction.platform.text) else {
                            throw ExhaustableDiagnostic.caseAvailabilityUnsupported
                        }
                        versions.append(restriction.trimmedDescription)
                    case let .availabilityLabeledArgument(labeled):
                        switch labeled.label.text {
                            case "introduced":
                                guard let platform, isRuntimePlatform(platform) else {
                                    throw ExhaustableDiagnostic.caseAvailabilityUnsupported
                                }
                                versions.append("\(platform) \(labeled.value.trimmedDescription)")
                            case "obsoleted":
                                // The case is namable below the obsoletion version and not at or above it, which `#available` states only in reverse.
                                throw ExhaustableDiagnostic.caseAvailabilityUnsupported
                            default:
                                break
                        }
                }
            }
        }
        return versions.isEmpty ? .always : .guarded(versions)
    }

    /// Whether a version restriction names an operating system, which is the only kind `#available` can test.
    ///
    /// A `swift` or `_PackageDescription` restriction gates compilation rather than execution. `#available` rejects it outright, and the guarded case stays unavailable inside the check, so neither half of the runtime path works.
    private static func isRuntimePlatform(_ platform: String) -> Bool {
        platform != "swift" && platform != "_PackageDescription"
    }

    /// Allows only products whose stored fields can be passed directly to a memberwise initializer and recovered unchanged by extraction.
    ///
    /// The reported access is the narrowest access any stored property has, counting an unwritten modifier as internal.
    ///
    /// Valid source cannot give a property a wider access than its own type, so this level also bounds how visible a generated initializer naming those types may be. Syntax cannot resolve a type's access, so the property's own access is the only sound proxy: a `public` class holding an unannotated field of an internal type would otherwise be given a `public` initializer that names an internal type and does not compile. Capping at internal matches Swift, which never synthesizes a `public` memberwise initializer either.
    private static func productProperties(
        in members: MemberBlockItemListSyntax,
        allowingDirectInitializer: Bool = false
    ) throws -> (properties: [StoredProperty], access: AccessLevel) {
        let initializers = members.compactMap { $0.decl.as(InitializerDeclSyntax.self) }
        var properties: [StoredProperty] = []
        var access = AccessLevel.publicScope
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
                access = min(access, accessLevel(variable.modifiers) ?? .moduleScope)
                properties.append(StoredProperty(name: identifier.identifier.trimmedDescription, type: type))
            }
        }
        guard initializers.isEmpty || (
            allowingDirectInitializer && initializers.count == 1
                && initializers.allSatisfy { isDirectMemberwise($0, properties: properties) }
        ) else {
            throw ExhaustableDiagnostic.customInitializerUnsupported
        }
        return (properties, access)
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
        return parameters?.parameters.contains { $0.specifier != nil } ?? false
    }

    /// Uses the effective enclosing access so an extension on a nested private type does not expose that type through an internal descriptor property. Raising `private` to `fileprivate` is what lets the expansion's separate extension still see the type.
    private static func accessPrefix(for modifiers: DeclModifierListSyntax, lexicalContext: [Syntax]) -> String {
        max(accessLevel(for: modifiers, lexicalContext: lexicalContext), .fileScope).prefix
    }

    private static func accessLevel(for modifiers: DeclModifierListSyntax, lexicalContext: [Syntax]) -> AccessLevel {
        let enclosing = lexicalContext.compactMap { declaration in
            declaration.as(EnumDeclSyntax.self)?.modifiers
                ?? declaration.as(StructDeclSyntax.self)?.modifiers
                ?? declaration.as(ClassDeclSyntax.self)?.modifiers
                ?? declaration.as(ActorDeclSyntax.self)?.modifiers
        }
        return ([modifiers] + enclosing).compactMap { accessLevel($0) ?? .moduleScope }.min() ?? .moduleScope
    }

    /// Returns nil when no access modifier is written, leaving each caller to supply the default its own question needs.
    private static func accessLevel(_ modifiers: DeclModifierListSyntax) -> AccessLevel? {
        let names = modifiers.map(\.name.text)
        if names.contains("private") {
            return .typeScope
        }
        if names.contains("fileprivate") {
            return .fileScope
        }
        if names.contains("package") {
            return .packageScope
        }
        if names.contains("public") || names.contains("open") {
            return .publicScope
        }
        return nil
    }

    /// Orders effective visibility so a nested declaration cannot expose its enclosing type.
    ///
    /// ``typeScope`` and ``fileScope`` stay apart because the compiler accepts only `private` on a member whose signature names a `private` type; `fileprivate` is rejected there. Each expansion site picks its own floor: a witness in a separate extension raises `typeScope` away, an initializer emitted into the type body keeps it.
    private enum AccessLevel: Int, Comparable {
        case typeScope
        case fileScope
        case moduleScope
        case packageScope
        case publicScope

        var prefix: String {
            switch self {
                case .typeScope:
                    "private "
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
    case caseAvailabilityUnsupported

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
            case .caseAvailabilityUnsupported:
                "@Exhaustable supports an introduced operating-system version or an unconditional @available(*, unavailable) on an enum case, but not a Swift version, obsoletion, or platform-specific unavailability; write a generator for this type instead"
        }
    }

    var diagnosticID: MessageID {
        MessageID(domain: "ExhaustMacros", id: rawValue)
    }

    var severity: DiagnosticSeverity {
        .error
    }
}
