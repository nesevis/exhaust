//
//  TycheReportingTests.swift
//  ExhaustTests
//
//  Tests for the Tyche reporting framework including console reporting,
//  file output, event recording, and error handling.
//

import Foundation
import Testing
@testable import Exhaust

@Suite("Tyche Reporting Framework")
struct TycheReportingTests {
    @Suite("Console Reporting")
    struct ConsoleReportingTests {
        @Test("Basic console reporting functionality")
        func basicConsoleReporting() {
            let result = TycheReportContext.withReporting(reporters: [ConsoleReporter(verbosity: .summary)]) {
                "test completed"
            }

            #expect(result == "test completed")
        }

        @Test("Reporting context lifecycle management")
        func reportingContextLifecycle() {
            #expect(!TycheReportContext.isReportingEnabled, "Reporting should be disabled initially")

            TycheReportContext.withReporting(reporters: [ConsoleReporter()]) {
                #expect(TycheReportContext.isReportingEnabled, "Reporting should be enabled in context")
            }

            #expect(!TycheReportContext.isReportingEnabled, "Reporting should be disabled after context")
        }
    }

    @Suite("File Output")
    struct FileOutputTests {
        @Test("JSON file reporting")
        func jsonReporting() {
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("tyche_test_\(UUID().uuidString).json")

            let result = TycheReportContext.withReporting(reporters: [JSONReporter(outputURL: tempURL)]) {
                "json test completed"
            }

            #expect(result == "json test completed")

            // Verify file was created
            #expect(FileManager.default.fileExists(atPath: tempURL.path))

            // Clean up
            try? FileManager.default.removeItem(at: tempURL)
        }
    }

    @Suite("Event Recording")
    struct EventRecordingTests {
        @Test("Manual event recording")
        func manualEventRecording() {
            var recordedEvents = false

            TycheReportContext.withReporting(reporters: [ConsoleReporter(verbosity: .summary)]) {
                // Record a generation event
                let metadata = GenerationMetadata(
                    operationType: "test",
                    generatorType: "Int",
                    size: 10,
                    duration: 0.001,
                )
                TycheReportContext.safeRecordGeneration(42, metadata: metadata)

                // Record a test outcome
                let outcome = TestOutcome(
                    wasSuccessful: true,
                    totalDuration: 0.01,
                )
                TycheReportContext.safeRecordTestOutcome(outcome)

                recordedEvents = true
            }

            #expect(recordedEvents, "Should have recorded events successfully")
        }

        @Test("Report generation functionality")
        func reportGeneration() {
            var generatedReport: TycheReport?

            TycheReportContext.withReporting(reporters: [ConsoleReporter(verbosity: .summary)]) {
                // Generate some basic test data
                let metadata = GenerationMetadata(
                    operationType: "test",
                    generatorType: "Int",
                    size: 10,
                    duration: 0.001,
                )
                TycheReportContext.safeRecordGeneration(42, metadata: metadata)

                generatedReport = TycheReportContext.current?.generateReport()
            }

            #expect(generatedReport != nil, "Should generate a report")

            if let report = generatedReport {
                #expect(report.reportTimestamp <= Date(), "Report timestamp should be valid")
            }
        }
    }

    @Suite("Error Handling")
    struct ErrorHandlingTests {
        @Test("Error handling during reporting")
        func errorHandling() {
            struct TestError: Error {}

            #expect(throws: TestError.self) {
                try TycheReportContext.withReporting(reporters: [ConsoleReporter()]) {
                    throw TestError()
                }
            }
        }

        @Test("Reporting context cleanup after exception")
        func reportingContextAfterException() {
            struct TestError: Error {}

            #expect(!TycheReportContext.isReportingEnabled, "Reporting should be disabled initially")

            do {
                try TycheReportContext.withReporting(reporters: [ConsoleReporter()]) {
                    #expect(TycheReportContext.isReportingEnabled, "Reporting should be enabled in context")
                    throw TestError()
                }
            } catch {
                // Expected
            }

            #expect(!TycheReportContext.isReportingEnabled, "Reporting should be disabled after exception")
        }
    }
}
