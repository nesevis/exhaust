import Testing
@testable import ExhaustCore

// MARK: - SCADomain.build

@Suite("SCADomain.build")
struct SCADomainBuildTests {
    @Test("Builds domain for parameter-free branches with full strength cap")
    func parameterFreeBranches() {
        let pickChoices = makeParameterFreeChoices(count: 3)
        let domain = SCADomain.build(
            sequenceLength: 5,
            pickChoices: pickChoices,
            coverageBudget: 2000,
            strengthCap: 5
        )
        #expect(domain != nil)
        #expect(domain?.mapping != nil)
        // No analyzed arguments, so strength cap passes through
        #expect(domain?.maxStrength == 5)
        #expect(domain?.profile.parameters.count == 5)
    }

    @Test("Builds domain with argument mapping for parameterized branches")
    func parameterizedBranches() {
        let pickChoices = makeParameterizedChoices()
        let domain = SCADomain.build(
            sequenceLength: 4,
            pickChoices: pickChoices,
            coverageBudget: 2000,
            strengthCap: 6
        )
        #expect(domain != nil)
        #expect(domain?.mapping != nil)
        // Argument-aware domains with analyzed branches cap at t=2
        #expect(domain!.maxStrength <= 2)
    }

    @Test("Passes through strength cap for parameter-free branches")
    func strengthCapPassthrough() {
        let pickChoices = makeParameterFreeChoices(count: 2)

        let domain2 = SCADomain.build(sequenceLength: 3, pickChoices: pickChoices, coverageBudget: 2000, strengthCap: 2)
        let domain6 = SCADomain.build(sequenceLength: 3, pickChoices: pickChoices, coverageBudget: 2000, strengthCap: 6)
        #expect(domain2?.maxStrength == 2)
        #expect(domain6?.maxStrength == 6)
    }
}

// MARK: - SCADomain.buildTree

@Suite("SCADomain.buildTree")
struct SCADomainBuildTreeTests {
    @Test("Builds tree from domain with parameter-free branches")
    func buildTreeParameterFree() {
        let pickChoices = makeParameterFreeChoices(count: 3)
        let domain = SCADomain.build(
            sequenceLength: 3,
            pickChoices: pickChoices,
            coverageBudget: 2000,
            strengthCap: 3
        )!

        var generator = PullBasedCoveringArrayGenerator(
            domainSizes: domain.profile.domainSizes,
            strength: min(domain.maxStrength, domain.profile.parameterCount, 4)
        )
        defer { generator.deallocate() }

        let lengthRange = UInt64(0) ... UInt64(3)
        var treeCount = 0
        var rowCount = 0
        while let row = generator.next() {
            rowCount += 1
            if domain.buildTree(row: row, sequenceLengthRange: lengthRange) != nil {
                treeCount += 1
            }
        }
        #expect(treeCount == rowCount)
    }

    @Test("Builds tree from domain with parameterized branches")
    func buildTreeParameterized() {
        let pickChoices = makeParameterizedChoices()
        guard let domain = SCADomain.build(
            sequenceLength: 3,
            pickChoices: pickChoices,
            coverageBudget: 2000,
            strengthCap: 2
        ) else {
            Issue.record("SCADomain.build returned nil")
            return
        }
        #expect(domain.mapping != nil)

        var generator = PullBasedCoveringArrayGenerator(
            domainSizes: domain.profile.domainSizes,
            strength: min(domain.maxStrength, domain.profile.parameterCount, 4)
        )
        defer { generator.deallocate() }

        let lengthRange = UInt64(0) ... UInt64(3)
        var treeCount = 0
        while let row = generator.next() {
            if domain.buildTree(row: row, sequenceLengthRange: lengthRange) != nil {
                treeCount += 1
            }
        }
        #expect(treeCount > 0)
    }

    @Test("buildTree returns nil for row with wrong value count")
    func mismatchedRowReturnsNil() {
        let pickChoices = makeParameterFreeChoices(count: 2)
        let domain = SCADomain.build(
            sequenceLength: 3,
            pickChoices: pickChoices,
            coverageBudget: 2000,
            strengthCap: 3
        )!

        // Row has 2 values but profile expects 3 parameters
        let badRow = CoveringArrayRow(values: [0, 1])
        let tree = domain.buildTree(row: badRow, sequenceLengthRange: 0 ... 3)
        #expect(tree == nil)
    }
}

// MARK: - Helpers

private func makeParameterFreeChoices(count: Int) -> ContiguousArray<ReflectiveOperation.PickTuple> {
    var choices = ContiguousArray<ReflectiveOperation.PickTuple>()
    for i in 0 ..< count {
        choices.append(ReflectiveOperation.PickTuple(
            fingerprint: UInt64(i),
            id: UInt64(i),
            weight: 1,
            generator: .pure(())
        ))
    }
    return choices
}

private func makeParameterizedChoices() -> ContiguousArray<ReflectiveOperation.PickTuple> {
    // Branch 0: parameter-free
    // Branch 1: has a chooseBits parameter (Gen.choose(in: 0...4))
    let paramFree = ReflectiveOperation.PickTuple(
        fingerprint: 0, id: 0, weight: 1,
        generator: .pure(())
    )
    let parameterized = ReflectiveOperation.PickTuple(
        fingerprint: 1, id: 1, weight: 1,
        generator: Gen.choose(in: 0 ... 4).erase()
    )
    return [paramFree, parameterized]
}
