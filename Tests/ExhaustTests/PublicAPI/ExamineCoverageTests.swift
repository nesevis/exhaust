import Testing
@testable import Exhaust

@Suite("#examine coverage metrics")
struct ExamineCoverageTests {
    // MARK: - Decile Coverage

    @Test("Integer generator covers its range deciles")
    func integerDecileCoverage() {
        let report = #examine(.int(in: 0 ... 1000), .samples(200), .suppress(.issueReporting))
        let intEntry = report.numericCoverage.first { $0.type == "Int" }
        #expect(intEntry != nil)
        #expect(intEntry!.decilesCovered >= 7)
    }

    @Test("UInt generator covers its range deciles")
    func unsignedDecileCoverage() {
        let report = #examine(.uint(in: 0 ... 10000), .samples(200), .suppress(.issueReporting))
        let uintEntry = report.numericCoverage.first { $0.type == "UInt" }
        #expect(uintEntry != nil)
        #expect(uintEntry!.decilesCovered >= 7)
    }

    @Test("Double generator covers its range deciles")
    func doubleDecileCoverage() {
        let report = #examine(.double(in: 0.0 ... 1000.0), .samples(200), .suppress(.issueReporting))
        let doubleEntry = report.numericCoverage.first { $0.type == "Double" }
        #expect(doubleEntry != nil)
        #expect(doubleEntry!.decilesCovered >= 3)
    }

    @Test("Small domain is excluded from decile computation")
    func smallDomainExcluded() {
        let report = #examine(.int(in: 0 ... 5), .samples(50), .suppress(.issueReporting))
        let intEntry = report.numericCoverage.first { $0.type == "Int" }
        #expect(intEntry == nil)
    }

    @Test("Multiple TypeTags reported separately")
    func multipleTypeTags() {
        let gen = #gen(.int(in: 0 ... 1000), .double(in: 0.0 ... 100.0))
        let report = gen.gen.validate(
            samples: 200,
            seed: 1,
            reporting: ExamineReportingConfiguration(from: [.suppress(.issueReporting)])
        )
        let intEntry = report.numericCoverage.first { $0.type == "Int" }
        let doubleEntry = report.numericCoverage.first { $0.type == "Double" }
        #expect(intEntry != nil)
        #expect(doubleEntry != nil)
    }

    // MARK: - Branch Coverage

    @Test("Enum generator achieves full branch coverage")
    func enumBranchCoverage() {
        let report = #examine(
            .oneOf(.just("a"), .just("b"), .just("c")),
            .samples(100),
            .suppress(.issueReporting)
        )
        #expect(report.branchCoverage == 1.0)
    }

    @Test("Branch coverage is vacuously 1.0 when no picks exist")
    func noBranchesVacuouslyTrue() {
        let report = #examine(.int(in: 0 ... 100), .samples(50), .suppress(.issueReporting))
        #expect(report.branchCoverage == 1.0)
        #expect(report.valuesGenerated == 50)
        #expect(report.sequenceLengthDeciles == 10)
        #expect(report.characterVariety == 1.0)
        #expect(report.complexityDeciles == 10)
        #expect(report.representativeTree != nil)
    }

    @Test("Bool generator covers both branches")
    func boolBranchCoverage() {
        let report = #examine(.bool(), .samples(50), .suppress(.issueReporting))
        #expect(report.branchCoverage == 1.0)
        #expect(report.numericCoverage.isEmpty)
    }

    // MARK: - Sequence Length Deciles

    @Test("Array generator covers sequence length deciles")
    func arrayLengthDeciles() {
        let report = #examine(
            .int(in: 0 ... 100).array(length: 0 ... 20),
            .samples(200),
            .suppress(.issueReporting)
        )
        #expect(report.sequenceLengthDeciles >= 5)
        #expect(report.complexityDeciles >= 5)
        #expect(report.valuesGenerated == 200)
    }

    // MARK: - Character Variety

    @Test("Character generator produces variety")
    func characterVariety() {
        let report = #examine(.character(), .samples(200), .suppress(.issueReporting))
        #expect(report.characterVariety > 0)
    }

    @Test("Complex generator report")
    func complexGeneratorProducesRepresentableReport() {
        struct Person {
            let firstName: String
            let lastName: String
            let age: UInt
        }
        let gen = #gen(.string(), .asciiString(), .uint(in: 0 ... 120)) {
            Person(firstName: $0, lastName: $1, age: $2)
        }.filter { $0.age >= 18 }
        let report = #examine(gen, .suppress(.issueReporting))
        #expect(report.filterObservations.isEmpty == false)
    }

    @Test("Complex generator with bind report")
    func complexGeneratorWithBindProducesRepresentableReport() {
        struct Person {
            let firstName: String
            let lastName: String
            let age: UInt
        }
        let gen = #gen(.string(), .asciiString(), .uint(in: 0 ... 120)) {
            Person(firstName: $0, lastName: $1, age: $2)
        }.bound(
            forward: { .oneOf(.just($0), .just($0)) },
            backward: { $0 }
        )
        let report = #examine(gen, .samples(200), .suppress(.issueReporting))
        // There will be a mismatch in the roundtrip because it's hard to pick which branch to take
        #expect(report.failures.isEmpty == false)
    }

    // MARK: - Complexity Deciles

    // MARK: - Representative Tree

    // MARK: - Suppress Settings

    @Test("Suppress configuration resolves correctly")
    func suppressResolution() {
        let logsConfig = ExamineReportingConfiguration(from: [.suppress(.logs)])
        #expect(logsConfig.suppress.logs == true)
        #expect(logsConfig.suppress.issueReporting == false)

        let issueConfig = ExamineReportingConfiguration(from: [.suppress(.issueReporting)])
        #expect(issueConfig.suppress.logs == false)
        #expect(issueConfig.suppress.issueReporting == true)

        let allConfig = ExamineReportingConfiguration(from: [.suppress(.all)])
        #expect(allConfig.suppress.logs == true)
        #expect(allConfig.suppress.issueReporting == true)
    }

    @Test("Suppress issue reporting prevents test failures")
    func suppressIssueReportingPreventsFailures() {
        let gen = #gen(.int(in: 1 ... 100)).mapped(
            forward: { $0 * 2 },
            backward: { $0 }
        )
        let report = gen.gen.validate(
            samples: 10,
            seed: 42,
            reporting: ExamineReportingConfiguration(from: [.suppress(.issueReporting)])
        )
        #expect(report.passed == false)
    }

    // MARK: - Filter Type

    @Test("Filter observation includes filter type")
    func filterTypeTracked() {
        let gen = #gen(.int(in: 0 ... 100, scaling: .constant)).filter(.rejectionSampling) { $0 >= 50 }
        let report = gen.gen.validate(
            samples: 50,
            seed: 42,
            reporting: ExamineReportingConfiguration(from: [.suppress(.issueReporting)])
        )
        let observation = report.filterObservations.values.first
        #expect(observation?.filterType == .rejectionSampling)
    }

    // MARK: - Report Description

    @Test("Report description includes coverage section")
    func reportDescriptionIncludesCoverage() {
        let report = #examine(.int(in: 0 ... 1000), .samples(100), .suppress(.issueReporting))
        let description = report.description
        #expect(description.contains("#examine:"))
        #expect(description.contains("Correctness:"))
        #expect(description.contains("Unique:"))
    }

    // MARK: - Assertion Patterns

    @Test("Users can assert all deciles cover a minimum")
    func assertAllDecilesCoverMinimum() {
        let report = #examine(.int(in: 0 ... 10000), .samples(200), .suppress(.issueReporting))
        #expect(report.numericCoverage.isEmpty == false)
        #expect(report.numericCoverage.allSatisfy { $0.decilesCovered >= 5 })
    }
}
