import ExhaustCore
import Testing

// MARK: - CommandTypeSCABuilder

@Suite("CommandTypeSCABuilder")
struct CommandTypeSCABuilderTests {
    @Test("Builds domain for parameter-free branches")
    func parameterFreeBranches() {
        let pickChoices = makeParameterFreeChoices(count: 3)
        let builder = CommandTypeSCABuilder()
        let domain = builder.buildDomain(
            sequenceLength: 5,
            pickChoices: pickChoices,
            coverageBudget: 2000,
            strengthCap: 4
        )
        #expect(domain != nil)
        #expect(domain?.mapping == nil)
        #expect(domain?.maxStrength == 4)
        #expect(domain?.profile.parameters.count == 5)
        #expect(domain?.profile.parameters[0].domainSize == 3)
    }

    @Test("Returns nil when branches have parameters")
    func rejectsParameterizedBranches() {
        let pickChoices = makeParameterizedChoices()
        let builder = CommandTypeSCABuilder()
        let domain = builder.buildDomain(
            sequenceLength: 5,
            pickChoices: pickChoices,
            coverageBudget: 2000,
            strengthCap: 4
        )
        #expect(domain == nil)
    }

    @Test("Passes through strength cap unchanged")
    func strengthCapPassthrough() {
        let pickChoices = makeParameterFreeChoices(count: 2)
        let builder = CommandTypeSCABuilder()

        let domain2 = builder.buildDomain(sequenceLength: 3, pickChoices: pickChoices, coverageBudget: 2000, strengthCap: 2)
        let domain6 = builder.buildDomain(sequenceLength: 3, pickChoices: pickChoices, coverageBudget: 2000, strengthCap: 6)
        #expect(domain2?.maxStrength == 2)
        #expect(domain6?.maxStrength == 6)
    }
}

// MARK: - ArgumentAwareSCABuilder

@Suite("ArgumentAwareSCABuilder")
struct ArgumentAwareSCABuilderTests {
    @Test("Builds domain with argument mapping for parameterized branches")
    func parameterizedBranches() {
        let pickChoices = makeParameterizedChoices()
        let builder = ArgumentAwareSCABuilder()
        let domain = builder.buildDomain(
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

    @Test("Builds domain for parameter-free branches with full strength cap")
    func parameterFreeBranches() {
        let pickChoices = makeParameterFreeChoices(count: 3)
        let builder = ArgumentAwareSCABuilder()
        let domain = builder.buildDomain(
            sequenceLength: 5,
            pickChoices: pickChoices,
            coverageBudget: 2000,
            strengthCap: 5
        )
        #expect(domain != nil)
        #expect(domain?.mapping != nil)
        // No analyzed arguments, so strength cap passes through
        #expect(domain?.maxStrength == 5)
    }
}

// MARK: - SCADomain.buildTree

@Suite("SCADomain.buildTree")
struct SCADomainBuildTreeTests {
    @Test("Builds tree from domain without mapping (command-type-only)")
    func buildTreeWithoutMapping() {
        let pickChoices = makeParameterFreeChoices(count: 3)
        let builder = CommandTypeSCABuilder()
        let domain = builder.buildDomain(
            sequenceLength: 3,
            pickChoices: pickChoices,
            coverageBudget: 2000,
            strengthCap: 3
        )!

        let covering = CoveringArray.bestFitting(
            budget: 2000,
            profile: domain.profile,
            maxStrength: domain.maxStrength
        )!

        let lengthRange = UInt64(0) ... UInt64(3)
        var treeCount = 0
        for row in covering.rows {
            if domain.buildTree(row: row, sequenceLengthRange: lengthRange) != nil {
                treeCount += 1
            }
        }
        #expect(treeCount == covering.rows.count)
    }

    @Test("Builds tree from domain with mapping (argument-aware)")
    func buildTreeWithMapping() {
        let pickChoices = makeParameterizedChoices()
        let builder = ArgumentAwareSCABuilder()
        guard let domain = builder.buildDomain(
            sequenceLength: 3,
            pickChoices: pickChoices,
            coverageBudget: 2000,
            strengthCap: 2
        ) else {
            Issue.record("ArgumentAwareSCABuilder returned nil")
            return
        }
        #expect(domain.mapping != nil)

        guard let covering = CoveringArray.bestFitting(
            budget: 2000,
            profile: domain.profile,
            maxStrength: domain.maxStrength
        ) else {
            Issue.record("CoveringArray.bestFitting returned nil")
            return
        }

        let lengthRange = UInt64(0) ... UInt64(3)
        var treeCount = 0
        for row in covering.rows {
            if domain.buildTree(row: row, sequenceLengthRange: lengthRange) != nil {
                treeCount += 1
            }
        }
        #expect(treeCount > 0)
    }

    @Test("buildTree returns nil for row with wrong value count")
    func mismatchedRowReturnsNil() {
        let pickChoices = makeParameterFreeChoices(count: 2)
        let builder = CommandTypeSCABuilder()
        let domain = builder.buildDomain(
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

// MARK: - Builder Selection

@Suite("SCADomainBuilder selection")
struct SCADomainBuilderSelectionTests {
    @Test("Protocol dispatch selects correct builder")
    func protocolDispatch() {
        let pickChoices = makeParameterFreeChoices(count: 2)
        let commandTypeBuilder: any SCADomainBuilder = CommandTypeSCABuilder()
        let argAwareBuilder: any SCADomainBuilder = ArgumentAwareSCABuilder()

        let domain1 = commandTypeBuilder.buildDomain(
            sequenceLength: 3, pickChoices: pickChoices, coverageBudget: 2000, strengthCap: 4
        )
        let domain2 = argAwareBuilder.buildDomain(
            sequenceLength: 3, pickChoices: pickChoices, coverageBudget: 2000, strengthCap: 4
        )

        // Both should succeed for parameter-free branches
        #expect(domain1 != nil)
        #expect(domain2 != nil)
        // Command-type has no mapping; argument-aware always has mapping
        #expect(domain1?.mapping == nil)
        #expect(domain2?.mapping != nil)
    }
}

// MARK: - Helpers

private func makeParameterFreeChoices(count: Int) -> ContiguousArray<ReflectiveOperation.PickTuple> {
    var choices = ContiguousArray<ReflectiveOperation.PickTuple>()
    for i in 0 ..< count {
        choices.append(ReflectiveOperation.PickTuple(
            siteID: UInt64(i),
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
        siteID: 0, id: 0, weight: 1,
        generator: .pure(())
    )
    let parameterized = ReflectiveOperation.PickTuple(
        siteID: 1, id: 1, weight: 1,
        generator: Gen.choose(in: 0 ... 4).erase()
    )
    return [paramFree, parameterized]
}
