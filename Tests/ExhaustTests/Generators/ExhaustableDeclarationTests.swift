import Exhaust
import ExhaustCore
import Testing

@Suite("Compiled @Exhaustable declarations")
struct ExhaustableDeclarationTests {
    @Test("Swift's memberwise initializer remains available beside extension initializers")
    func structConstruction() throws {
        let entry = try #require(DeclarationProduct.__generatorDescriptor.constructors.first)
        #expect(entry.payloadTypes.count == 3)
        let value = entry.embed([7, "generated", 4])
        #expect(value.identifier == 7)
        #expect(value.label == "generated")
        #expect(value.observed == 4)
        let payloads = try #require(entry.extract(value))
        #expect(payloads.count == 3)
        #expect(payloads[0] as? Int == 7)
        #expect(payloads[1] as? String == "generated")
        #expect(payloads[2] as? Int == 4)
        let custom = DeclarationProduct(9)
        #expect(custom.identifier == 9)
        #expect(custom.label == "initial")
        let generator = ReflectiveGenerator<DeclarationProduct>.derived(depth: 0)
        let tree = try #require(try Interpreters.reflect(generator.gen, with: value))
        #expect(try Interpreters.replay(generator.gen, using: tree) == value)
    }

    @Test("A final class initializes every field and can adopt protocols in an extension")
    func classConstruction() throws {
        let entry = try #require(DeclarationClass.__generatorDescriptor.constructors.first)
        #expect(entry.payloadTypes.count == 2)
        let value = entry.embed([7, "generated"])
        #expect(value.count == 7)
        #expect(value.label == "generated")
        #expect(value == DeclarationClass(count: 7, label: "generated"))
        let payloads = try #require(entry.extract(value))
        #expect(payloads.count == 2)
        #expect(payloads[0] as? Int == 7)
        #expect(payloads[1] as? String == "generated")
        let generator = ReflectiveGenerator<DeclarationClass>.derived(depth: 0)
        let tree = try #require(try Interpreters.reflect(generator.gen, with: value))
        let replayed = try #require(try Interpreters.replay(generator.gen, using: tree))
        #expect(replayed == value)
        #expect(replayed !== value)
    }

    @Test("A public final class exposes a usable generated initializer and descriptor")
    func publicClassConstruction() {
        let value = DeclarationPublicClass(count: 7)
        #expect(value.count == 7)
        #expect(DeclarationPublicClass.__generatorDescriptor.constructors.count == 1)
    }

    @Test("Nested types in a private scope receive usable descriptor witnesses")
    func privateNestedConstruction() throws {
        let product = try #require(DeclarationNamespace.Product.__generatorDescriptor.constructors.first).embed([3])
        let record = try #require(DeclarationNamespace.Record.__generatorDescriptor.constructors.first).embed([4])
        #expect(product.count == 3)
        #expect(record.count == 4)
    }

    @Test("Expansion metadata remains namespaced beside matching user type names")
    func namespacedMetadata() throws {
        let descriptor: __Exhaustable.TypeDescriptor<DeclarationMetadataNamespace.Product> =
            DeclarationMetadataNamespace.Product.__generatorDescriptor
        let entry: __Exhaustable.ConstructorDescriptor<DeclarationMetadataNamespace.Product> =
            try #require(descriptor.constructors.first)
        #expect(entry.payloadTypes.count == 1)
        #expect(ObjectIdentifier(entry.payloadTypes[0]) == ObjectIdentifier(Int.self))
        let value = entry.embed([7])
        #expect(value == DeclarationMetadataNamespace.Product(count: 7))
        let payloads = try #require(entry.extract(value))
        #expect(payloads.count == 1)
        #expect(payloads[0] as? Int == 7)
        let generator = DeclarationMetadataNamespace.Product.gen()
        let tree = try #require(try Interpreters.reflect(generator.gen, with: value))
        #expect(try Interpreters.replay(generator.gen, using: tree) == value)
    }

    @Test("A synthesized class initializer accepts an escaping stored function")
    func storedFunctionConstruction() throws {
        let entry = try #require(DeclarationFunction.__generatorDescriptor.constructors.first)
        let transform: @Sendable (Int) -> Int = { $0 + 1 }
        let value = entry.embed([transform])
        #expect(value.transform(7) == 8)
        let payloads = try #require(entry.extract(value))
        let extracted = try #require(payloads[0] as? (@Sendable (Int) -> Int))
        #expect(extracted(9) == 10)
        #expect(DeclarationFunction(transform: transform).transform(2) == 3)
    }

    @Test("Explicit wildcard and named enum labels compile and retain payload order")
    func enumLabels() throws {
        let constructors = DeclarationEnum.__generatorDescriptor.constructors
        #expect(constructors.map(\.name) == ["empty", "unlabelled", "labelled"])
        #expect(constructors[0].embed([]) == .empty)
        #expect(constructors[1].embed([3]) == .unlabelled(3))
        let value = constructors[2].embed([7, "payload"])
        #expect(value == .labelled(number: 7, text: "payload"))
        let payloads = try #require(constructors[2].extract(value))
        #expect(payloads.count == 2)
        #expect(payloads[0] as? Int == 7)
        #expect(payloads[1] as? String == "payload")
        #expect(constructors[1].extract(value) == nil)
    }

    @Test("Empty products have valid zero-argument construction")
    func emptyProducts() throws {
        let structure = try #require(DeclarationEmptyStruct.__generatorDescriptor.constructors.first)
        let record = try #require(DeclarationEmptyClass.__generatorDescriptor.constructors.first)
        #expect(structure.payloadTypes.isEmpty)
        #expect(record.payloadTypes.isEmpty)
        #expect(structure.extract(structure.embed([]))?.isEmpty == true)
        #expect(record.extract(record.embed([]))?.isEmpty == true)
    }
}

// MARK: - Compile-time fixtures

@Exhaustable
private struct DeclarationProduct: Equatable {
    let identifier: Int
    var label: String = "initial"
    var observed: Int = 0 {
        didSet { _ = observed }
    }

    static let ignored = 42
    var computed: Int {
        identifier * 2
    }
}

private extension DeclarationProduct {
    init(_ identifier: Int) {
        self.identifier = identifier
    }
}

@Exhaustable
private final class DeclarationClass {
    let count: Int
    var label: String = "initial"
}

extension DeclarationClass: Equatable {
    static func == (left: DeclarationClass, right: DeclarationClass) -> Bool {
        left.count == right.count && left.label == right.label
    }
}

/// Checks that generated public members satisfy the infrastructure protocol and remain callable.
@Exhaustable
public final class DeclarationPublicClass {
    /// Provides the payload for the generated public initializer.
    public let count: Int
}

private enum DeclarationNamespace {
    @Exhaustable
    struct Product {
        let count: Int
    }

    @Exhaustable
    final class Record {
        let count: Int
    }
}

private enum DeclarationMetadataNamespace {
    struct Conformance {}
    struct TypeDescriptor {}
    struct ConstructorDescriptor {}

    @Exhaustable
    struct Product: Equatable {
        let count: Int
    }
}

@Exhaustable
private final class DeclarationFunction {
    let transform: @Sendable (Int) -> Int
}

@Exhaustable
private enum DeclarationEnum: Equatable {
    case empty
    case unlabelled(_ value: Int)
    case labelled(number: Int, text: String)
}

@Exhaustable
private struct DeclarationEmptyStruct {}

@Exhaustable
private final class DeclarationEmptyClass {}
