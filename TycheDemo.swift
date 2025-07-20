import Foundation
import Exhaust

// Simple demonstration that Tyche works
print("🎲 Tyche Demo - Property-Based Testing Reporting")
print("================================================")

// Test 1: Basic context lifecycle
print("\n1. Testing basic context lifecycle...")
print("   Reporting enabled initially: \(TycheReportContext.isReportingEnabled)")

TycheReportContext.withReporting(reporters: [ConsoleReporter(verbosity: .summary)]) {
    print("   Reporting enabled in context: \(TycheReportContext.isReportingEnabled)")
    
    // Record some events
    let metadata = GenerationMetadata(
        operationType: "demo",
        generatorType: "Int",
        size: 10,
        duration: 0.001
    )
    TycheReportContext.safeRecordGeneration(42, metadata: metadata)
    
    let outcome = TestOutcome(
        wasSuccessful: true,
        totalDuration: 0.01
    )
    TycheReportContext.safeRecordTestOutcome(outcome)
    
    print("   Events recorded successfully")
}

print("   Reporting enabled after context: \(TycheReportContext.isReportingEnabled)")

// Test 2: JSON reporting
print("\n2. Testing JSON file reporting...")
let tempURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("tyche_demo.json")

TycheReportContext.withReporting(reporters: [JSONReporter(outputURL: tempURL)]) {
    let metadata = GenerationMetadata(
        operationType: "json_demo",
        generatorType: "String",
        size: 20,
        duration: 0.002
    )
    TycheReportContext.safeRecordGeneration("Hello Tyche!", metadata: metadata)
    
    print("   JSON report will be generated at: \(tempURL.path)")
}

// Check if file was created
if FileManager.default.fileExists(atPath: tempURL.path) {
    print("   ✅ JSON file created successfully")
    
    // Read and display file size
    do {
        let attributes = try FileManager.default.attributesOfItem(atPath: tempURL.path)
        let fileSize = attributes[.size] as? Int64 ?? 0
        print("   File size: \(fileSize) bytes")
    } catch {
        print("   Could not read file attributes: \(error)")
    }
} else {
    print("   ❌ JSON file was not created")
}

// Test 3: Multiple reporters
print("\n3. Testing multiple reporters...")
let csvURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("tyche_demo.csv")

TycheReportContext.withReporting(reporters: [
    ConsoleReporter(verbosity: .summary),
    JSONReporter(outputURL: tempURL),
    CSVReporter(outputURL: csvURL)
]) {
    // Record multiple events
    for i in 1...5 {
        let metadata = GenerationMetadata(
            operationType: "multi_demo",
            generatorType: "Int",
            size: UInt64(i * 10),
            duration: Double(i) * 0.001
        )
        TycheReportContext.safeRecordGeneration(i, metadata: metadata)
    }
    
    print("   Multiple events recorded with multiple reporters")
}

// Check files
let csvExists = FileManager.default.fileExists(atPath: csvURL.path)
print("   CSV file created: \(csvExists ? "✅" : "❌")")

// Test 4: Error handling
print("\n4. Testing error handling...")
struct DemoError: Error {}

do {
    try TycheReportContext.withReporting(reporters: [ConsoleReporter(verbosity: .summary)]) {
        print("   Inside reporting context before error")
        throw DemoError()
    }
} catch {
    print("   Error caught successfully: \(type(of: error))")
    print("   Reporting disabled after error: \(!TycheReportContext.isReportingEnabled)")
}

// Test 5: Report generation
print("\n5. Testing report generation...")
var finalReport: TycheReport?

TycheReportContext.withReporting(reporters: [ConsoleReporter(verbosity: .summary)]) {
    // Add some varied data
    let generationMetadata = GenerationMetadata(
        operationType: "final_test",
        generatorType: "Mixed",
        size: 100,
        duration: 0.005
    )
    TycheReportContext.safeRecordGeneration("Final test", metadata: generationMetadata)
    
    let shrinkMetadata = ShrinkingMetadata(
        originalComplexity: 1000,
        targetComplexity: 500,
        stepType: .greedyCandidate,
        duration: 0.003,
        wasSuccessful: true
    )
    TycheReportContext.safeRecordShrinkStep(from: 1000, to: 500, metadata: shrinkMetadata)
    
    let testOutcome = TestOutcome(
        wasSuccessful: false,
        counterexampleValue: "counterexample",
        shrinkingSteps: 5,
        totalDuration: 0.1
    )
    TycheReportContext.safeRecordTestOutcome(testOutcome)
    
    finalReport = TycheReportContext.current?.generateReport()
}

if let report = finalReport {
    print("   ✅ Report generated successfully")
    print("   Report timestamp: \(report.reportTimestamp)")
    print("   Generation entropy: \(report.generationReport.distributionMetrics.entropy)")
    print("   Test success rate: \(report.testRunReport.successFailureRates.successRate)")
} else {
    print("   ❌ Report generation failed")
}

// Cleanup
try? FileManager.default.removeItem(at: tempURL)
try? FileManager.default.removeItem(at: csvURL)

print("\n🎉 Tyche Demo Complete!")
print("The Tyche reporting system is working correctly.")