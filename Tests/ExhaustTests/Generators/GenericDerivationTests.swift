import Exhaust
import ExhaustCore
import ExhaustTestSupport
import Testing
@testable import ExhaustGenerators

@Suite("Generic generator derivation")
struct GenericDerivationTests {
    @Test("Generic structs resolve concrete payloads without constraints on the declaration")
    func products() throws {
        let generator = GenericBox<Int>.gen(overriding: .int(in: 7 ... 7))
        let samples = try #example(generator, count: 20)
        #expect(samples.allSatisfy { $0.value == 7 })
        try expectReflectionRoundTrip(generator.gen, value: GenericBox(value: 7))
        try expectReflectionRoundTrip(GenericAssociated<[Int]>.gen().gen, value: GenericAssociated(value: 4))
    }

    @Test("Generic final classes receive a memberwise initializer and reversible metadata")
    func finalClasses() throws {
        let generator = GenericReference<Int>.gen(overriding: .int(in: 7 ... 7))
        let samples = try #example(generator, count: 20)
        #expect(samples.allSatisfy { $0.value == 7 })
        let target = GenericReference(value: 7)
        let reflected = try #require(try Interpreters.reflect(generator.gen, with: target))
        let replayed = try #require(try Interpreters.replay(generator.gen, using: reflected))
        #expect(replayed.value == target.value)
    }

    @Test("Nested declarations resolve parameters from their enclosing generic scope")
    func nestedDeclarations() throws {
        try expectReflectionRoundTrip(GenericScope<Int>.Nested.gen().gen, value: .init(value: 7))
        try expectReflectionRoundTrip(GenericScope<Int>.Pair<Bool>.gen().gen, value: .init(first: 7, second: true))
    }

    @Test("Nested recursive generic enums qualify their own payload type")
    func nestedRecursiveEnums() throws {
        let generator = GenericNestedRecursiveScope.Heap<Int>.gen(recursion: 2, .domain(.tiny))
        let target = GenericNestedRecursiveScope.Heap<Int>.node(7, .empty, .empty)
        try expectReflectionRoundTrip(generator.gen, value: target)
    }

    @Test("Recursive generic enums terminate, reflect, and replay across node ceilings", arguments: [31, 100])
    func recursiveEnums(maximumNodes: Int) throws {
        let plan = try GeneratorDerivationPlan(for: GenericTree<Int>.self, overrides: [:])
        #expect(plan.types.count == 1)
        let generator = GenericTree<Int>.gen(.budget(.custom(recursion: 4, nodes: maximumNodes)), .domain(.tiny))
        let target = GenericTree<Int>.branch(.value(3), .branch(.empty, .value(5)))
        try expectReflectionRoundTrip(generator.gen, value: target)
        let report = #examine(generator, .samples(50), .replay(42), .suppress(.all)) { $0 == $1 }
        expectSuccessfulExamination(report, samples: 50)
    }

    @Test("Arrays of the same generic specialization close the dependency graph")
    func recursiveArrays() throws {
        let plan = try GeneratorDerivationPlan(for: GenericArrayTree<Int>.self, overrides: [:])
        #expect(plan.types.count == 1)
        let generator = GenericArrayTree<Int>.gen(recursion: 1, .domain(.tiny))
        try expectReflectionRoundTrip(generator.gen, value: .children([.value(7), .children([])]))
        let report = #examine(generator, .samples(50), .replay(42), .suppress(.all)) { $0 == $1 }
        expectSuccessfulExamination(report, samples: 50)
    }

    @Test("Generic payload values need not be Sendable")
    func nonSendablePayload() throws {
        let payload = GenericMutablePayload()
        let generator = GenericBox<GenericMutablePayload>.gen(overriding: .just(payload))
        let samples = try #example(generator, count: 20)
        #expect(samples.allSatisfy { $0.value === payload })
    }

    @Test("Repeated generic declarations keep distinct concrete specializations")
    func distinctSpecializations() throws {
        let plan = try GeneratorDerivationPlan(for: GenericProducts.self, overrides: [:])
        #expect(plan.types.count == 3)
        #expect(plan.types[ObjectIdentifier(GenericBox<Int>.self)] != nil)
        #expect(plan.types[ObjectIdentifier(GenericBox<Bool>.self)] != nil)
        let generator = GenericProducts.gen(overriding: .int(in: 7 ... 7), .just(true))
        let target = GenericProducts(integer: GenericBox(value: 7), flag: GenericBox(value: true))
        let samples = try #example(generator, count: 20)
        #expect(samples.allSatisfy { $0 == target })
        try expectReflectionRoundTrip(generator.gen, value: target)
    }

    @Test("Generic container payloads retain element overrides and recorded replay")
    func containers() throws {
        let generator = GenericContainers<Int>.gen(.budget(.custom(recursion: 10, nodes: 32)), overriding: .int(in: 7 ... 7))
        #expect(generator.isReflective == false)
        var interpreter = ValueAndChoiceTreeInterpreter(generator.gen, seed: 42, sizeOverride: 100)
        var sawArray = false
        var sawSet = false
        var sawDictionary = false
        for _ in 0 ..< 50 {
            let (value, choices) = try #require(try interpreter.next())
            #expect(value.array.allSatisfy { $0 == 7 })
            #expect(value.optional == nil || value.optional == 7)
            #expect(value.set.allSatisfy { $0 == 7 })
            #expect(value.dictionary.allSatisfy { $0.key == 7 && $0.value.value == 7 })
            #expect(try Interpreters.replay(generator.gen, using: choices) == value)
            sawArray = sawArray || value.array.isEmpty == false
            sawSet = sawSet || value.set.isEmpty == false
            sawDictionary = sawDictionary || value.dictionary.isEmpty == false
        }
        #expect(sawArray, "every draw had an empty array, so the element override was never applied there")
        #expect(sawSet, "every draw had an empty set, so the element override was never applied there")
        #expect(sawDictionary, "every draw had an empty dictionary, so the element override was never applied there")
    }

    @Test("Unsupported generic arguments require an override, not a generic conformance constraint")
    func unsupportedPayloadOverride() throws {
        #expect(throws: GeneratorDerivationError.unsupportedPayload(type: "GenericOpaque")) {
            try GeneratorDerivationPlan(for: GenericBox<GenericOpaque>.self, overrides: [:])
        }
        let value = GenericOpaque(number: 7)
        let generator = GenericBox<GenericOpaque>.gen(overriding: .just(value))
        let samples = try #example(generator, count: 20)
        #expect(samples.allSatisfy { $0.value == value })
        try expectReflectionRoundTrip(generator.gen, value: GenericBox(value: value))
    }

    @Test("Changing generic arguments may close a finite cycle or settle on a fixed specialization")
    func finiteSpecializationChanges() throws {
        let swapping = try GeneratorDerivationPlan(for: GenericSwap<Int, Bool>.self, overrides: [:])
        #expect(swapping.types.count == 2)
        let target = GenericSwap<Int, Bool>.next(.next(.value(7, true)))
        try expectReflectionRoundTrip(GenericSwap<Int, Bool>.gen(.budget(.custom(recursion: 3, nodes: 100))).gen, value: target)
        let settling = try GeneratorDerivationPlan(for: GenericSettles<Bool>.self, overrides: [:])
        #expect(settling.types.count == 2)
        try expectReflectionRoundTrip(GenericSettles<Bool>.gen(.budget(.custom(recursion: 3, nodes: 100))).gen, value: .next(.value(7)))
    }

    @Test("Unbounded generic specialization fails with a bounded discovery diagnostic")
    func expandingSpecializations() throws {
        #expect(throws: GeneratorDerivationError.specializationLimitExceeded(
            type: String(describing: GenericExpansion<Int>.self),
            limit: GeneratorDerivationPlan.maximumActiveSpecializations
        )) {
            try GeneratorDerivationPlan(for: GenericExpansion<Int>.self, overrides: [:])
        }
        #expect(throws: GeneratorDerivationError.specializationLimitExceeded(
            type: String(describing: GenericExpandingFirst<Int>.self),
            limit: GeneratorDerivationPlan.maximumActiveSpecializations
        )) {
            try GeneratorDerivationPlan(for: GenericExpandingFirst<Int>.self, overrides: [:])
        }
    }

    @Test("The discovery safeguard admits its documented finite boundary")
    func finiteDiscoveryBoundary() throws {
        let plan = try GeneratorDerivationPlan(for: GenericThirtyTwo.self, overrides: [:])
        #expect(plan.types.count == 32)
        #expect(try plan.minimumRecursionBudget(for: GenericThirtyTwo.self, at: 0) == 0)
        typealias TwoDeepBranches = GenericScope<GenericThirtyTwo>.Pair<GenericSixteen<GenericSixteen<Bool>>>
        let branched = try GeneratorDerivationPlan(for: TwoDeepBranches.self, overrides: [:])
        #expect(branched.types.count == 65)
        #expect(try branched.minimumRecursionBudget(for: TwoDeepBranches.self, at: 0) == 0)
        #expect(throws: GeneratorDerivationError.specializationLimitExceeded(
            type: String(describing: GenericBox<GenericThirtyTwo>.self),
            limit: 32
        )) {
            try GeneratorDerivationPlan(for: GenericBox<GenericThirtyTwo>.self, overrides: [:])
        }
    }

    @Test("An exact override can terminate an otherwise expanding generic dependency")
    func terminatesExpansionWithOverride() throws {
        let supplied = ReflectiveGenerator<GenericExpansion<[Int]>>.just(.end)
        let plan = try GeneratorDerivationPlan(
            for: GenericExpansion<Int>.self,
            overrides: [ObjectIdentifier(GenericExpansion<[Int]>.self): supplied.erasedForDerivation()]
        )
        #expect(plan.types.count == 1)
        let generator = GenericExpansion<Int>.gen(recursion: 1, overriding: supplied)
        let samples = try #example(generator, count: 20)
        for sample in samples {
            switch sample {
                case .end, .next(.end):
                    break
                case .next(.next):
                    Issue.record("The override must terminate the expanding payload")
            }
        }
    }
}

// MARK: - Fixtures

@Exhaustable
private struct GenericBox<Element> {
    let value: Element
}

extension GenericBox: Equatable where Element: Equatable {}

@Exhaustable
private final class GenericReference<Element> {
    let value: Element
}

@Exhaustable
private struct GenericAssociated<Values: Collection>: Equatable where Values.Element: Hashable {
    let value: Values.Element
}

private struct GenericScope<Element: Equatable> {
    @Exhaustable
    struct Nested: Equatable {
        let value: Element
    }

    @Exhaustable
    struct Pair<Other: Equatable>: Equatable {
        let first: Element
        let second: Other
    }
}

private enum GenericNestedRecursiveScope {
    @Exhaustable
    indirect enum Heap<Element: Comparable>: Equatable {
        case empty
        case node(Element, Heap, Heap)
    }
}

@Exhaustable
private indirect enum GenericTree<Element> {
    case empty
    case value(Element)
    case branch(GenericTree<Element>, GenericTree<Element>)
}

extension GenericTree: Equatable where Element: Equatable {}

@Exhaustable
private indirect enum GenericArrayTree<Element> {
    case value(Element)
    case children([GenericArrayTree<Element>])
}

extension GenericArrayTree: Equatable where Element: Equatable {}

private final class GenericMutablePayload {
    var number = 7
}

private typealias GenericFour<Value> = GenericBox<GenericBox<GenericBox<GenericBox<Value>>>>
private typealias GenericSixteen<Value> = GenericFour<GenericFour<GenericFour<GenericFour<Value>>>>
private typealias GenericThirtyTwo = GenericSixteen<GenericSixteen<Int>>

@Exhaustable
private struct GenericProducts: Equatable {
    let integer: GenericBox<Int>
    let flag: GenericBox<Bool>
}

@Exhaustable
private struct GenericContainers<Element: Hashable>: Equatable {
    let array: [Element]
    let optional: Element?
    let set: Set<Element>
    let dictionary: [Element: GenericBox<Element>]
}

private struct GenericOpaque: Equatable {
    let number: Int
}

@Exhaustable
private indirect enum GenericSwap<First, Second> {
    case value(First, Second)
    case next(GenericSwap<Second, First>)
}

extension GenericSwap: Equatable where First: Equatable, Second: Equatable {}

@Exhaustable
private indirect enum GenericSettles<Element> {
    case value(Element)
    case next(GenericSettles<Int>)
}

extension GenericSettles: Equatable where Element: Equatable {}

@Exhaustable
private indirect enum GenericExpansion<Element> {
    case end
    case next(GenericExpansion<[Element]>)
}

@Exhaustable
private indirect enum GenericExpandingFirst<Element> {
    case end
    case next(GenericExpandingSecond<[Element]>)
}

@Exhaustable
private indirect enum GenericExpandingSecond<Element> {
    case first(GenericExpandingFirst<Element>)
}

// MARK: - Helpers
