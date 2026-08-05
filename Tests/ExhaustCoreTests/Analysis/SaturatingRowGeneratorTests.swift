import Testing
@testable import ExhaustCore

@Suite("Saturating row generation")
struct SaturatingRowGeneratorTests {
    @Test("Emits every point of the space exactly once", arguments: [UInt64(0), 1, 12345])
    func emitsEveryPointOnce(seed: UInt64) {
        let domainSizes: [UInt64] = [2, 3, 4]
        let generator = SaturatingRowGenerator(domainSizes: domainSizes, seed: seed)

        var rows: [[UInt64]] = []
        while let row = generator.next() {
            rows.append(row.values)
        }

        #expect(rows.count == 24)
        #expect(Set(rows.map(\.description)).count == 24)
        #expect(rows.allSatisfy { zip($0, domainSizes).allSatisfy { value, size in value < size } })
    }

    @Test("Leads with the covering array's distinct rows before completing the space")
    func leadsWithCoveringRows() {
        let domainSizes: [UInt64] = [2, 3, 4]
        let covering = BalancedCoveringArrayGenerator(domainSizes: domainSizes, seed: 7)
        var seenRows: Set<[UInt64]> = []
        var distinctCoveringRows: [[UInt64]] = []
        while let row = covering.next() {
            if seenRows.insert(row.values).inserted {
                distinctCoveringRows.append(row.values)
            }
        }

        let generator = SaturatingRowGenerator(domainSizes: domainSizes, seed: 7)
        var prefix: [[UInt64]] = []
        for _ in 0 ..< distinctCoveringRows.count {
            guard let row = generator.next() else {
                break
            }
            prefix.append(row.values)
        }

        #expect(prefix == distinctCoveringRows)
    }

    @Test("A domain above the spread threshold still saturates")
    func saturatesAboveSpreadThreshold() {
        // 65 exceeds BalancedCoveringArrayGenerator.greedyThreshold, so an unforced covering generator would take the spread path, never report exhaustion, and the remainder would never run.
        let domainSizes: [UInt64] = [65, 3]
        let generator = SaturatingRowGenerator(domainSizes: domainSizes, seed: 9)

        var rows: [[UInt64]] = []
        while let row = generator.next() {
            rows.append(row.values)
        }

        #expect(rows.count == 195)
        #expect(Set(rows.map(\.description)).count == 195)
    }

    @Test("Exhaustive enumeration visits the whole space in odometer order")
    func exhaustiveOdometerOrder() {
        let generator = ExhaustiveRowGenerator(domainSizes: [2, 2])
        var rows: [[UInt64]] = []
        while let row = generator.next() {
            rows.append(row.values)
        }
        #expect(rows == [[0, 0], [0, 1], [1, 0], [1, 1]])
    }

    @Test("Total space saturates rather than overflowing")
    func totalSpaceSaturates() {
        #expect(ExhaustiveRowGenerator.totalSpace(of: [2, 3, 4]) == 24)
        #expect(ExhaustiveRowGenerator.totalSpace(of: [UInt64.max, 2]) == .max)
    }
}
