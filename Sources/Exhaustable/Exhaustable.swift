/// Namespaces the metadata and conformance emitted by ``Exhaustable(maximumDepth:maximumNodes:stateSpace:)``.
///
/// These declarations are public only because macro expansions in application modules must name them. They are implementation infrastructure, not user conformance or customization points. The namespace has no dependency on ExhaustCore, so an annotated application type does not link generator or interpreter code.
public enum __Exhaustable { // swiftlint:disable:this type_name
    /// Supplies construction metadata for an annotated type.
    ///
    /// Apply `@Exhaustable` rather than conforming manually. Importing `ExhaustGenerators` or `Exhaust` then exposes the annotated type's `gen(...)` factory.
    public protocol Conformance {
        /// Describes the type's constructors in declaration order.
        static var __generatorDescriptor: TypeDescriptor<Self> { get }
    }

    /// Describes the constructors of an annotated type. An enum has one constructor per case; a struct or final class has one constructor whose payload is its stored properties.
    public struct TypeDescriptor<Value> {
        /// Lists constructors in declaration order.
        public let constructors: [ConstructorDescriptor<Value>]

        /// Bounds nesting through annotated payloads when the declaration specifies a ceiling; `nil` leaves the choice to the derivation.
        public let maximumDepth: Int?

        /// Caps structural nodes when specified. Each annotated value, standard container, and opaque payload costs one node; descendants consume the remainder.
        public let maximumNodes: Int?

        /// Narrows inherited default-payload sampling; `.full` leaves the parent's state space unchanged.
        public let stateSpace: GeneratorStateSpace

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
        ///   - maximumDepth: The declared nesting ceiling for this type inside itself, or `nil` to leave the choice to the derivation.
        ///   - maximumNodes: The declared structural node ceiling, or `nil` for no node ceiling.
        ///   - stateSpace: The default-payload sampling policy this type applies to its occurrences.
        ///   - fileID: The module-qualified source file identifier, not an absolute path.
        ///   - line: The one-based source line of the declaration's annotation.
        ///   - column: The one-based source column of the declaration's annotation.
        public init(
            constructors: [ConstructorDescriptor<Value>],
            maximumDepth: Int? = nil,
            maximumNodes: Int? = nil,
            stateSpace: GeneratorStateSpace = .full,
            fileID: StaticString = #fileID,
            line: UInt = #line,
            column: UInt = #column
        ) {
            self.constructors = constructors
            self.maximumDepth = maximumDepth
            self.maximumNodes = maximumNodes
            self.stateSpace = stateSpace
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
/// Start without arguments. Set limits here only when every derived use of the type should inherit them; an individual test can override the root settings through `Type.gen(...)`.
///
/// The macro supports enums, structs, final classes, and generic forms of those declarations. It diagnoses unsupported storage and initialization patterns at the declaration.
///
/// - Parameters:
///   - maximumDepth: The default recursive nesting ceiling. Defaults to 10.
///   - maximumNodes: An optional default structural node ceiling. Defaults to no node ceiling.
///   - stateSpace: The default breadth of numeric, sequence, and date payloads. Defaults to `.full`; see ``GeneratorStateSpace``.
@attached(extension, conformances: __Exhaustable.Conformance, names: named(__generatorDescriptor))
@attached(member, names: named(init))
public macro Exhaustable(
    maximumDepth: Int? = nil,
    maximumNodes: Int? = nil,
    stateSpace: GeneratorStateSpace = .full
) = #externalMacro(module: "ExhaustMacros", type: "ExhaustableMacro")
