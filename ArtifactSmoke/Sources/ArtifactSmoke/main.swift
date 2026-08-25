import Exhaust
import Foundation

// Exercises the public surface the way an external consumer does, against the binary artifact: run failing properties, keep every report in an array, then copy them back out. Copying `ExhaustReport` values from an array is where a layout mismatch between this module's view of the struct and the artifact's surfaces as a crash.

struct Person: Codable, Equatable {
    let name: String
    let age: UInt
    let tags: [String]
}

nonisolated(unsafe) var reports: [ExhaustReport] = []
nonisolated(unsafe) var failures: [String] = []

func check(_ condition: Bool, _ message: String) {
    if condition == false {
        failures.append(message)
    }
}

/// Integer arrays: sequence batch path, reduction, replay.
let arrayCounterexample = #exhaust(
    #gen(.int(in: 0 ... 1000).array(length: 0 ... 50)),
    .budget(.custom(screening: 0, sampling: 5000)),
    .suppress(.all),
    .replay(.numeric(1337)),
    .onReport { reports.append($0) }
) { values in
    values.reduce(0, +) < 2000
}

check(arrayCounterexample != nil, "integer array property did not fail")

/// Strings and a filter: character batch path and the tuned-filter cache.
let stringCounterexample = #exhaust(
    #gen(.asciiString(length: 1 ... 30)).filter { $0.contains(" ") == false },
    .budget(.custom(screening: 0, sampling: 5000)),
    .suppress(.all),
    .replay(.numeric(7)),
    .onReport { reports.append($0) }
) { text in
    text.count < 12
}

check(stringCounterexample != nil, "string property did not fail")

// Synthesized struct generator, uniqueness, and a passing run (report without reduction fields).
do {
    let synthesized = try #gen(from: Person(name: "Gaute", age: 30, tags: ["a", "b"]))
    let passing = #exhaust(
        synthesized.unique(),
        .budget(.custom(screening: 0, sampling: 500)),
        .suppress(.all),
        .replay(.numeric(3)),
        .onReport { reports.append($0) }
    ) { _ in
        true
    }
    check(passing == nil, "passing property reported a counterexample")
} catch {
    failures.append("synthesis failed: \(error)")
}

/// Reflection entry point.
let reflected = #exhaust(
    #gen(.int(in: 0 ... 100).array(length: 1 ... 10)),
    reflecting: [90, 91, 92],
    .suppress(.all),
    .onReport { reports.append($0) }
) { values in
    values.allSatisfy { $0 < 50 }
}

check(reflected != nil, "reflecting run did not fail")

// The consumer crash path: copy every report out of the array and read it.
check(reports.count == 4, "expected 4 reports, got \(reports.count)")
var copies: [ExhaustReport] = []
for report in reports {
    copies.append(report)
}

var totalInvocations = 0
for report in copies {
    totalInvocations += report.propertyInvocations
    _ = report.profilingSummary
    _ = report.replaySeed
    _ = report.filterObservations.count
    _ = report.reductionStalled
    _ = report.reductionFailed
}

check(totalInvocations > 0, "reports carried no invocations")
check(reports[0].reductionInvocations > 0, "integer array run did not reduce")
check(reports[1].reductionInvocations > 0, "string run did not reduce")

if failures.isEmpty {
    print("ArtifactSmoke: OK (\(reports.count) reports, \(totalInvocations) invocations)")
    exit(0)
}

for failure in failures {
    print("ArtifactSmoke: FAIL: \(failure)")
}

exit(1)
