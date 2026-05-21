import ExhaustCore
import Foundation
import IssueReporting

/// Entry point for GCD-based concurrent contract testing with sync commands and oracle comparison.
///
/// Expanded by `#exhaust(ConcurrentContractSpec.self, ...)`. Runs a sequential smoke test first, then dispatches commands across real GCD threads and uses the spec's ``ConcurrentContractSpec/oracleCheck(_:)`` to verify consistency with sequential behavior.
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
@discardableResult
public func __runPreemptiveConcurrentContract<Spec: ConcurrentContractSpec>(
    _ specType: Spec.Type,
    settings: [ConcurrentContractSettings],
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
) -> ContractResult<Spec>? {
    // TODO: Implement GCD concurrent contract runner
    // Phase 1: Sequential smoke test (reuse existing sequential runner)
    // Phase 2: GCD concurrent execution with incremental oracle checking
    // Phase 3: Three-pass reduction (lane collapse → structural → cosmetic)
    reportIssue(
        "GCD concurrent contract testing is not yet implemented",
        fileID: fileID,
        filePath: filePath,
        line: line,
        column: column
    )
    return nil
}

/// Entry point for GCD-based concurrent contract testing with async commands and oracle comparison.
///
/// Expanded by `#exhaust(AsyncConcurrentContractSpec.self, ...)`. Same as ``__runPreemptiveConcurrentContract`` but for specs with async commands.
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
@discardableResult
public func __runPreemptiveConcurrentContractAsync<Spec: AsyncConcurrentContractSpec>(
    _ specType: Spec.Type,
    settings: [ConcurrentContractSettings],
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
) async -> ContractResult<Spec>? {
    // TODO: Implement async GCD concurrent contract runner
    reportIssue(
        "Async GCD concurrent contract testing is not yet implemented",
        fileID: fileID,
        filePath: filePath,
        line: line,
        column: column
    )
    return nil
}
