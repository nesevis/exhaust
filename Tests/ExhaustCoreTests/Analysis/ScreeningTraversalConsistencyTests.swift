import Testing
@testable import ExhaustCore

@Suite("Screening traversal consistency")
struct ScreeningTraversalConsistencyTests {
    @Test("Both profile kinds preserve wrappers and consume the same numeric sites")
    func matchingReconstruction() throws {
        let template = wrappedTree(first: 0, second: 1)
        let expected = ChoiceSequence(wrappedTree(first: 1, second: 0))
        for result in reconstructBoth(template, parameters: [factor(0), factor(1)], values: [1, 0]) {
            let rebuilt = try #require(result)
            #expect(ChoiceSequence(rebuilt) == expected)
        }
    }

    @Test("Too few or unused parameters reject instead of shifting the row")
    func rejectsCountMismatch() {
        for result in reconstructBoth(.group([choice(0), choice(0)]), parameters: [factor(0)], values: [1]) {
            #expect(result == nil)
        }
        for result in reconstructBoth(choice(0), parameters: [factor(0), factor(1)], values: [1, 0]) {
            #expect(result == nil)
        }
    }

    @Test("Wrong factor kinds, ranges, tags and indices reject in both profile kinds")
    func rejectsDomainMismatch() {
        let pick = EnumerableParameter(
            index: 0,
            domainSize: 1,
            kind: .pick(choices: [(.init(fingerprint: 1, id: 0, weight: 1, generator: .pure(())))])
        )
        let wrongRange = EnumerableParameter(index: 0, domainSize: 3, kind: .chooseBits(range: 0 ... 2, tag: .uint64))
        let wrongTag = EnumerableParameter(index: 0, domainSize: 2, kind: .chooseBits(range: 0 ... 1, tag: .uint8))
        for parameter in [pick, wrongRange, wrongTag] {
            for result in reconstructBoth(choice(0), parameters: [parameter], values: [0]) {
                #expect(result == nil)
            }
        }
        for index in [UInt64(2), UInt64.max] {
            for result in reconstructBoth(choice(0), parameters: [factor(0)], values: [index]) {
                #expect(result == nil)
            }
        }
    }

    @Test("Composite element reconstruction requires exact local parameter consumption")
    func rejectsElementMismatch() {
        let parameters = largeFactors([factor(0), factor(1)])
        let composite = ScreeningParameter(
            index: 0,
            values: [0, 1, 2, 3],
            domainSize: 4,
            kind: .compositeSequence(
                lengthRange: 1 ... 1,
                elementSlotParams: [parameters],
                halvedPairs: false,
                lengthSlots: [.init(length: 1, flatOffset: 0, contribution: 4, activeElementCount: 1)]
            )
        )
        let profile = LargeDomainProfile(
            parameters: [composite],
            originalTree: .sequence(elements: [choice(0)], metadata: ChoiceMetadata(validRange: 1 ... 1, isRangeExplicit: true))
        )
        #expect(CoveringArrayReplay.buildTree(row: CoveringArrayRow(values: [0]), profile: profile) == nil)
    }

    @Test("A selected arm from a multi-arm pick is not a transparent singleton")
    func partialPickIsNotSingleton() {
        let tree = ChoiceTree.group([.branch(
            fingerprint: 7,
            weight: 1,
            id: 0,
            branchCount: 2,
            choice: choice(0),
            isSelected: true
        )])
        guard case .pick = tree.screeningShape(in: .root) else {
            Issue.record("A partially recorded pick must still consume a branch parameter")
            return
        }
        for result in reconstructBoth(tree, parameters: [factor(0)], values: [0]) {
            #expect(result == nil)
        }
    }

    @Test("Excluded lane controls do not consume a sibling's parameter")
    func laneControlIsPreserved() throws {
        let control = ChoiceTree.choice(ChoiceValue(UInt64(1), tag: .laneControl), ChoiceMetadata(validRange: 0 ... 2, isRangeExplicit: true))
        let template = ChoiceTree.group([control, choice(0)], isZip: true)
        let expected = ChoiceSequence(.group([control, choice(1)], isZip: true))
        for result in reconstructBoth(template, parameters: [factor(0)], values: [1]) {
            #expect(try ChoiceSequence(#require(result)) == expected)
        }
    }
}

private func choice(_ value: UInt64) -> ChoiceTree {
    .choice(ChoiceValue(value, tag: .uint64), ChoiceMetadata(validRange: 0 ... 1, isRangeExplicit: true))
}

private func factor(_ index: Int) -> EnumerableParameter {
    EnumerableParameter(index: index, domainSize: 2, kind: .chooseBits(range: 0 ... 1, tag: .uint64))
}

/// Deliberately nests a fixed-context bind, resize, singleton pick and zip beside a value-dependent bind. Only the two ordinary input choices belong to the row.
private func wrappedTree(first: UInt64, second: UInt64) -> ChoiceTree {
    let depth = ChoiceTree.choice(ChoiceValue(UInt64(3), tag: .depthControl), ChoiceMetadata(validRange: 0 ... 3, isRangeExplicit: true))
    let singleton = ChoiceTree.group([.branch(
        fingerprint: 7,
        weight: 1,
        id: 0,
        branchCount: 1,
        choice: .group([depth, choice(first)], isZip: true),
        isSelected: true
    )])
    return .group([
        .bind(fingerprint: 5, inner: .getSize(100), bound: .resize(newSize: 37, choices: [singleton])),
        .bind(fingerprint: 6, inner: choice(second), bound: choice(1)),
    ], isZip: true)
}

/// Uses identical domains with both profile representations so parameter ordering cannot differ merely because one model uses lookup tables.
private func reconstructBoth(_ tree: ChoiceTree, parameters: [EnumerableParameter], values: [UInt64]) -> [ChoiceTree?] {
    let row = CoveringArrayRow(values: values)
    let totalSpace = parameters.reduce(UInt64(1)) { $0 * $1.domainSize }
    // This helper exercises substitution only. The template binds, so it witnesses less than the whole domain.
    let enumerable = EnumerableDomainProfile(
        parameters: parameters,
        totalSpace: totalSpace,
        template: AnalysisTemplate(substitutionTemplate: tree, isTotalWitness: false)
    )
    let large = LargeDomainProfile(parameters: largeFactors(parameters), originalTree: tree)
    return [CoveringArrayReplay.buildTree(row: row, profile: enumerable), CoveringArrayReplay.buildTree(row: row, profile: large)]
}

private func largeFactors(_ parameters: [EnumerableParameter]) -> [ScreeningParameter] {
    parameters.map { parameter in
        switch parameter.kind {
            case let .chooseBits(range, tag):
                ScreeningParameter(index: parameter.index, values: Array(range), domainSize: parameter.domainSize, kind: .enumerableChooseBits(range: range, tag: tag))
            case let .pick(choices):
                ScreeningParameter(index: parameter.index, values: Array(0 ..< parameter.domainSize), domainSize: parameter.domainSize, kind: .pick(choices: choices))
        }
    }
}
