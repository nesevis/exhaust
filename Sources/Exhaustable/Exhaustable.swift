// MARK: - Module Surface

//
// ExhaustGenerators re-exports this module whole, because a macro cannot be named in a scoped `@_exported import`. A new `public` declaration here joins the ExhaustGenerators and Exhaust surfaces with no line to add anywhere else, so treat one as public API and prefer `package` for anything the macro expansion and the annotation's arguments do not name.

/// Namespaces the metadata and conformance emitted by ``Exhaustable(_:)``.
///
/// These declarations are public only because macro expansions in application modules must name them. They are implementation infrastructure, not user conformance or customization points. The namespace has no dependency on ExhaustCore, so an annotated application type does not link generator or interpreter code.
public enum __Exhaustable { // swiftlint:disable:this type_name
    /// Supplies construction metadata for an annotated type.
    ///
    /// Apply `@Exhaustable` rather than conforming manually. Importing `ExhaustGenerators` or `Exhaust` then exposes the annotated type's `gen(...)` factory.
    public protocol Conformance: SendableMetatype {
        /// Describes the type's constructors in declaration order.
        ///
        /// The requirement is `nonisolated` because derivation reads it synchronously from whichever thread draws a value. A global-actor-isolated type satisfies it whenever its construction and its stored-property reads are themselves nonisolated, which covers a value type of `Sendable` payloads and a final class whose initializer the macro generates. Isolated state that genuinely needs the actor fails to compile at the annotated declaration rather than escaping the actor at run time.
        nonisolated static var __generatorDescriptor: TypeDescriptor<Self> { get }
    }

    /// Describes the constructors of an annotated type. An enum has one constructor per case; a struct or final class has one constructor whose payload is its stored properties.
    public struct TypeDescriptor<Value> {
        /// Lists constructors in declaration order.
        public let constructors: [ConstructorDescriptor<Value>]

        /// Controls recursive fuel and the complete structural node ceiling.
        public let budget: ExhaustableBudget

        /// Narrows inherited default-payload sampling; `.full` leaves the parent's domain unchanged.
        public let domain: ExhaustableDomain

        /// Identifies the declaration's source file without an absolute checkout path.
        public let fileID: StaticString

        /// Identifies the declaration's source line for its derived generator family.
        public let line: UInt

        /// Distinguishes declarations on the same source line.
        public let column: UInt

        /// Creates metadata with a source identity shared by the type's derived generators at every depth.
        ///
        /// The macro supplies the original annotation's location explicitly. Other construction sites default to this initializer's call site. Moving that location can change the family's fingerprint; launching another process does not.
        ///
        /// - Parameters:
        ///   - constructors: The type's constructors in declaration order.
        ///   - settings: The derivation settings from the annotation, resolved in declaration order.
        ///   - fileID: The module-qualified source file identifier, not an absolute path.
        ///   - line: The one-based source line of the declaration's annotation.
        ///   - column: The one-based source column of the declaration's annotation.
        public init(
            constructors: [ConstructorDescriptor<Value>],
            settings: [ExhaustableSettings] = [],
            fileID: StaticString = #fileID,
            line: UInt = #line,
            column: UInt = #column
        ) {
            let resolved = ResolvedExhaustableSettings(settings)
            self.constructors = constructors
            budget = resolved.budget
            domain = resolved.domain
            self.fileID = fileID
            self.line = line
            self.column = column
        }
    }

    /// Describes one sum-of-products constructor and the inverse operations that construct and decompose its values.
    public struct ConstructorDescriptor<Value> {
        /// Names the enum case or product type without argument labels.
        public let name: String

        /// Lists payload types in declaration order. Empty for a payload-free enum case or product.
        public let payloadTypes: [Any.Type]

        /// Builds the constructor from payload values in declaration order. Each element must have the matching entry's type in ``payloadTypes``.
        public let embed: ([Any]) -> Value

        /// Returns the constructor's payload values in declaration order, or `nil` when an enum value belongs to another constructor.
        public let extract: (Value) -> [Any]?

        /// Creates a constructor descriptor for a macro expansion.
        public init(
            name: String,
            payloadTypes: [Any.Type],
            embed: @escaping ([Any]) -> Value,
            extract: @escaping (Value) -> [Any]?
        ) {
            self.name = name
            self.payloadTypes = payloadTypes
            self.embed = embed
            self.extract = extract
        }
    }
}

/// Derives an Exhaust property-test generator for this type.
///
/// Add `@Exhaustable` in production code while importing only `Exhaustable`. Tests that import `Exhaust` can then call `Type.gen()`; the application target does not link the generator runtime.
///
/// ```swift
/// @Exhaustable
/// struct Order {
///     let itemNames: [String]
///     let priority: Int
/// }
///
/// // In a test target:
/// let orders = Order.gen()
/// ```
///
/// Start without arguments. Add settings here only when every derived use of the type should inherit them; an individual test can override the root through `Type.gen(...)`.
///
/// The macro supports enums, structs, final classes, and generic forms of those declarations. It diagnoses unsupported storage and initialization patterns at the declaration.
///
/// - Important: `@Exhaustable` is experimental. Its arguments, supported declarations, generated members, diagnostics, and source compatibility may change in any release.
///
/// Settings are variadic ``ExhaustableSettings`` values controlling the structural budget and sampled payload domain. The last occurrence of each setting wins.
///
/// - Parameter settings: Settings inherited by every derived occurrence of this type.
@attached(extension, conformances: __Exhaustable.Conformance, names: named(__generatorDescriptor))
@attached(member, names: named(init))
public macro Exhaustable(
    _ settings: ExhaustableSettings...
) = #externalMacro(module: "ExhaustMacros", type: "ExhaustableMacro")
