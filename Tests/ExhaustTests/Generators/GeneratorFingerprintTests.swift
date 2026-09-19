import Exhaust
import ExhaustCore
import Testing

@Suite("Derived generator fingerprints")
struct GeneratorFingerprintTests {
    @Test("Private and nested types retain their original annotation locations")
    func capturesDeclarationLocations() {
        let descriptor = FingerprintTree.__generatorDescriptor
        #expect(descriptor.fileID.description == #fileID)
        #expect(descriptor.line == fingerprintTreeAnnotationLine)
        #expect(descriptor.column == 1)

        let nested = FingerprintScope.FingerprintTree.__generatorDescriptor
        #expect(nested.fileID.description == #fileID)
        #expect(nested.line == FingerprintScope.annotationLine)
        #expect(nested.column == 5)
    }

    @Test("Every depth uses the declaration's source fingerprint", arguments: 0 ... 4)
    func sharesFamilyAcrossDepths(depth: Int) {
        let expected = Gen.sourceFingerprint(
            fileID: #fileID,
            line: fingerprintTreeAnnotationLine,
            column: 1
        )
        let generator = ReflectiveGenerator<FingerprintTree>.derived(depth: depth)
        let fingerprints = pickFingerprints(generator)
        #expect(fingerprints.count == (depth == 0 ? 1 : 2))
        #expect(Set(fingerprints) == [expected])

        let rebuilt = ReflectiveGenerator<FingerprintTree>.derived(depth: depth)
        #expect(pickFingerprints(rebuilt) == fingerprints)
    }

    @Test("Same-named declarations have distinct derived families")
    func separatesDeclarations() throws {
        let first = ReflectiveGenerator<FingerprintTree>.derived(depth: 2)
        let second = ReflectiveGenerator<FingerprintScope.FingerprintTree>.derived(depth: 2)
        let firstFingerprint = try #require(pickFingerprints(first).first)
        let secondFingerprint = try #require(pickFingerprints(second).first)
        #expect(firstFingerprint != secondFingerprint)
        #expect(secondFingerprint == Gen.sourceFingerprint(
            fileID: #fileID,
            line: FingerprintScope.annotationLine,
            column: 5
        ))
    }

    @Test("Recursive occurrences retain the root family through reflection and replay")
    func sharesFamilyWithDescendants() throws {
        let generator = ReflectiveGenerator<FingerprintTree>.derived(depth: 3)
        let value: FingerprintTree = .node(.node(.leaf))
        let tree = try #require(try Interpreters.reflect(generator.gen, with: value))
        let fingerprints = ChoiceSequence.flatten(tree).compactMap { entry -> UInt64? in
            guard case let .branch(branch) = entry else {
                return nil
            }
            return branch.fingerprint
        }
        let expected = Gen.sourceFingerprint(
            fileID: #fileID,
            line: fingerprintTreeAnnotationLine,
            column: 1
        )
        #expect(fingerprints.count == 3)
        #expect(Set(fingerprints) == [expected])
        let replayed = try #require(try Interpreters.replay(generator.gen, using: tree))
        #expect(replayed == value)
    }
}

// MARK: - Fixtures

private let fingerprintTreeAnnotationLine: UInt = #line + 1
@Exhaustable
private indirect enum FingerprintTree: Equatable {
    case leaf
    case node(FingerprintTree)
}

enum FingerprintScope {
    static let annotationLine: UInt = #line + 1
    @Exhaustable
    indirect enum FingerprintTree {
        case leaf
        case node(FingerprintScope.FingerprintTree)
    }
}

// MARK: - Helpers

private func pickFingerprints(_ generator: ReflectiveGenerator<some Any>) -> [UInt64] {
    guard case let .impure(.pick(choices, _), _) = generator.gen else {
        Issue.record("Expected a derived generator to start with a pick")
        return []
    }
    return choices.map(\.fingerprint)
}
