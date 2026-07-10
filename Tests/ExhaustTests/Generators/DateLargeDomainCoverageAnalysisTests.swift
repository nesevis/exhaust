//
//  DateLargeDomainCoverageAnalysisTests.swift
//  Exhaust
//
//  Diagnostic: measures which date problematic values actually appear in
//  covering array rows at each ExhaustBudget tier. Since both the
//  problematic-value analysis and PBCAG are deterministic, values that are not
//  covered at a given budget will NEVER be covered at that budget.
//

import Exhaust
import ExhaustTestSupport
import Foundation
import Testing

@Suite("Date Large Domain Coverage Analysis", .serialized)
struct DateLargeDomainCoverageAnalysis {
    static let year2024Start = Date(timeIntervalSinceReferenceDate: 725_760_000)
    static let year2024End = Date(timeIntervalSinceReferenceDate: 725_760_000 + 86400 * 366)
    static let year2024 = year2024Start ... year2024End
    static let usEastern = TimeZone(identifier: "America/New_York")!

    struct BudgetTier: CustomTestStringConvertible {
        let name: String
        let budget: UInt64
        var testDescription: String {
            name
        }
    }

    static let tiers: [BudgetTier] = [
        BudgetTier(name: "quick (100)", budget: 100),
        BudgetTier(name: "standard (200)", budget: 200),
        BudgetTier(name: "thorough (600)", budget: 600),
        BudgetTier(name: "extensive (2000)", budget: 2000),
    ]

    @Test("3 params: per-parameter coverage at each budget tier", arguments: tiers)
    func threeParamCoverage(tier: BudgetTier) throws {
        let dateGen = #gen(.date(
            between: Self.year2024, interval: .hours(1), timeZone: Self.usEastern
        ))
        let stringGen = #gen(.string(length: 1 ... 20))
        let gen = #gen(dateGen, dateGen, stringGen)

        let profile = try #require(analyzeLargeDomain(gen.gen, expand: false))
        let domainSizes = profile.domainSizes
        let paramCount = profile.parameterCount
        let strength = 2

        var coveredPerParam: [Set<UInt64>] = Array(repeating: [], count: paramCount)
        var coveredPairSet = Set<UInt64>()
        var rowCount = 0
        let generator = PullBasedCoveringArrayGenerator(domainSizes: domainSizes, strength: 2)

        while rowCount < Int(tier.budget), let row = generator.next() {
            for (paramIndex, valueIndex) in row.values.enumerated() {
                coveredPerParam[paramIndex].insert(valueIndex)
            }
            for i in 0 ..< paramCount {
                for j in (i + 1) ..< paramCount {
                    coveredPairSet.insert(pairKey(i, row.values[i], j, row.values[j]))
                }
            }
            rowCount += 1
        }

        let totalPairs = domainSizes.enumerated().flatMap { index, sizeA in
            domainSizes.dropFirst(index + 1).map { sizeB in Int(sizeA) * Int(sizeB) }
        }.reduce(0, +)
        let coveredPairs = coveredPairSet.count
        let exhausted = coveredPairs == totalPairs

        print("--- \(tier.name) ---")
        print("Rows emitted: \(rowCount) (exhausted: \(exhausted))")
        print("Pairwise tuples: \(coveredPairs)/\(totalPairs) covered (\(totalPairs - coveredPairs) remaining)")
        print("Parameters: \(profile.parameterCount), strength: \(strength)")
        print()

        for (index, parameter) in profile.parameters.enumerated() {
            let total = Int(parameter.domainSize)
            let hit = coveredPerParam[index].count
            let missed = total - hit
            let percentage = total > 0 ? Double(hit) / Double(total) * 100 : 100

            let kindLabel: String
            switch parameter.kind {
                case let .chooseBits(_, tag):
                    switch tag {
                        case .date:
                            kindLabel = "date"
                        case .character:
                            kindLabel = "character"
                        default:
                            kindLabel = "chooseBits"
                    }
                case .sequenceLength:
                    kindLabel = "sequenceLength"
                case .compositeSequence:
                    kindLabel = "compositeSequence"
                case .enumerableChooseBits:
                    kindLabel = "enumerableChooseBits"
                case .pick:
                    kindLabel = "pick"
                case .sequenceElement:
                    kindLabel = "sequenceElement"
            }

            print("  param[\(index)] \(kindLabel): \(hit)/\(total) covered (\(String(format: "%.0f", percentage))%), \(missed) never covered")

            if missed > 0 {
                let coveredIndices = coveredPerParam[index]
                let missingIndices = (0 ..< UInt64(total)).filter { coveredIndices.contains($0) == false }
                let missingValues = missingIndices.map { parameter.values[Int($0)] }
                print("    missing indices: \(missingIndices.prefix(20))\(missingIndices.count > 20 ? "..." : "")")
                print("    missing values:  \(missingValues.prefix(10))\(missingValues.count > 10 ? "..." : "")")
            }
        }
        print()
    }

    @Test("3 params: per-parameter coverage at each budget tier (rotated)", arguments: tiers)
    func threeParamCoverageRotated(tier: BudgetTier) throws {
        let dateGen = #gen(.date(
            between: Self.year2024, interval: .hours(1), timeZone: Self.usEastern
        ))
        let stringGen = #gen(.string(length: 1 ... 20))
        let gen = #gen(dateGen, dateGen, stringGen)

        let profile = try #require(analyzeLargeDomain(gen.gen, expand: false))
        let domainSizes = profile.domainSizes
        let paramCount = profile.parameterCount
        let strength = 2

        // Match ScreeningRunner: one PBCAG per parameter rotation for balanced coverage
        let rotations: [(generator: PullBasedCoveringArrayGenerator, offset: Int)] =
            (0 ..< paramCount).map { offset in
                let rotated = (0 ..< paramCount).map { domainSizes[($0 + offset) % paramCount] }
                return (PullBasedCoveringArrayGenerator(domainSizes: rotated, strength: strength), offset)
            }

        var coveredPerParam: [Set<UInt64>] = Array(repeating: [], count: paramCount)
        var coveredPairSet = Set<UInt64>()
        var rowCount = 0

        while rowCount < Int(tier.budget) {
            let (generator, offset) = rotations[rowCount % rotations.count]
            guard let rotatedRow = generator.next() else {
                rowCount += 1
                continue
            }

            let row: CoveringArrayRow
            if offset == 0 {
                row = rotatedRow
            } else {
                var canonical = [UInt64](repeating: 0, count: paramCount)
                for i in 0 ..< paramCount {
                    canonical[(i + offset) % paramCount] = rotatedRow.values[i]
                }
                row = CoveringArrayRow(values: canonical)
            }

            for (paramIndex, valueIndex) in row.values.enumerated() {
                coveredPerParam[paramIndex].insert(valueIndex)
            }
            for i in 0 ..< paramCount {
                for j in (i + 1) ..< paramCount {
                    coveredPairSet.insert(pairKey(i, row.values[i], j, row.values[j]))
                }
            }
            rowCount += 1
        }

        let totalPairs = domainSizes.enumerated().flatMap { index, sizeA in
            domainSizes.dropFirst(index + 1).map { sizeB in Int(sizeA) * Int(sizeB) }
        }.reduce(0, +)
        let coveredPairs = coveredPairSet.count
        let exhausted = coveredPairs == totalPairs

        print("--- \(tier.name) ---")
        print("Rows emitted: \(rowCount) (exhausted: \(exhausted))")
        print("Pairwise tuples: \(coveredPairs)/\(totalPairs) covered (\(totalPairs - coveredPairs) remaining, \(rotations.count) rotations)")
        print("Parameters: \(profile.parameterCount), strength: \(strength)")
        print()

        for (index, parameter) in profile.parameters.enumerated() {
            let total = Int(parameter.domainSize)
            let hit = coveredPerParam[index].count
            let missed = total - hit
            let percentage = total > 0 ? Double(hit) / Double(total) * 100 : 100

            let kindLabel: String
            switch parameter.kind {
                case let .chooseBits(_, tag):
                    switch tag {
                        case .date:
                            kindLabel = "date"
                        case .character:
                            kindLabel = "character"
                        default:
                            kindLabel = "chooseBits"
                    }
                case .sequenceLength:
                    kindLabel = "sequenceLength"
                case .compositeSequence:
                    kindLabel = "compositeSequence"
                case .enumerableChooseBits:
                    kindLabel = "enumerableChooseBits"
                case .pick:
                    kindLabel = "pick"
                case .sequenceElement:
                    kindLabel = "sequenceElement"
            }

            print("  param[\(index)] \(kindLabel): \(hit)/\(total) covered (\(String(format: "%.0f", percentage))%), \(missed) never covered")

            if missed > 0 {
                let coveredIndices = coveredPerParam[index]
                let missingIndices = (0 ..< UInt64(total)).filter { coveredIndices.contains($0) == false }
                let missingValues = missingIndices.map { parameter.values[Int($0)] }
                print("    missing indices: \(missingIndices.prefix(20))\(missingIndices.count > 20 ? "..." : "")")
                print("    missing values:  \(missingValues.prefix(10))\(missingValues.count > 10 ? "..." : "")")
            }
        }
        print()
    }

    @Test("3 params: BCAG per-parameter coverage at each budget tier", arguments: tiers)
    func threeParamCoverageBCAG(tier: BudgetTier) throws {
        let dateGen = #gen(.date(
            between: Self.year2024, interval: .hours(1), timeZone: Self.usEastern
        ))
        let stringGen = #gen(.string(length: 1 ... 20))
        let gen = #gen(dateGen, dateGen, stringGen)

        let profile = try #require(analyzeLargeDomain(gen.gen, expand: false))
        let domainSizes = profile.domainSizes
        let paramCount = profile.parameterCount

        let generator = BalancedCoveringArrayGenerator(domainSizes: domainSizes)

        var coveredPerParam: [Set<UInt64>] = Array(repeating: [], count: paramCount)
        var coveredPairSet = Set<UInt64>()
        var rowCount = 0

        while rowCount < Int(tier.budget), let row = generator.next() {
            for (paramIndex, valueIndex) in row.values.enumerated() {
                coveredPerParam[paramIndex].insert(valueIndex)
            }
            for i in 0 ..< paramCount {
                for j in (i + 1) ..< paramCount {
                    coveredPairSet.insert(pairKey(i, row.values[i], j, row.values[j]))
                }
            }
            rowCount += 1
        }

        let totalPairs = domainSizes.enumerated().flatMap { index, sizeA in
            domainSizes.dropFirst(index + 1).map { sizeB in Int(sizeA) * Int(sizeB) }
        }.reduce(0, +)
        let coveredPairs = coveredPairSet.count
        let exhausted = coveredPairs == totalPairs

        print("--- BCAG \(tier.name) ---")
        print("Rows emitted: \(rowCount) (exhausted: \(exhausted))")
        print("Pairwise tuples: \(coveredPairs)/\(totalPairs) covered (\(totalPairs - coveredPairs) remaining)")
        print("Parameters: \(profile.parameterCount), strength: 2")
        print()

        for (index, parameter) in profile.parameters.enumerated() {
            let total = Int(parameter.domainSize)
            let hit = coveredPerParam[index].count
            let missed = total - hit
            let percentage = total > 0 ? Double(hit) / Double(total) * 100 : 100

            let kindLabel: String
            switch parameter.kind {
                case let .chooseBits(_, tag):
                    switch tag {
                        case .date:
                            kindLabel = "date"
                        case .character:
                            kindLabel = "character"
                        default:
                            kindLabel = "chooseBits"
                    }
                case .sequenceLength:
                    kindLabel = "sequenceLength"
                case .compositeSequence:
                    kindLabel = "compositeSequence"
                case .enumerableChooseBits:
                    kindLabel = "enumerableChooseBits"
                case .pick:
                    kindLabel = "pick"
                case .sequenceElement:
                    kindLabel = "sequenceElement"
            }

            print("  param[\(index)] \(kindLabel): \(hit)/\(total) covered (\(String(format: "%.0f", percentage))%), \(missed) never covered")

            if missed > 0 {
                let coveredIndices = coveredPerParam[index]
                let missingIndices = (0 ..< UInt64(total)).filter { coveredIndices.contains($0) == false }
                let missingValues = missingIndices.map { parameter.values[Int($0)] }
                print("    missing indices: \(missingIndices.prefix(20))\(missingIndices.count > 20 ? "..." : "")")
                print("    missing values:  \(missingValues.prefix(10))\(missingValues.count > 10 ? "..." : "")")
            }
        }
        print()
    }
}

private func pairKey(_ paramA: Int, _ valueA: UInt64, _ paramB: Int, _ valueB: UInt64) -> UInt64 {
    var hasher = Hasher()
    hasher.combine(paramA)
    hasher.combine(valueA)
    hasher.combine(paramB)
    hasher.combine(valueB)
    return UInt64(bitPattern: Int64(hasher.finalize()))
}
