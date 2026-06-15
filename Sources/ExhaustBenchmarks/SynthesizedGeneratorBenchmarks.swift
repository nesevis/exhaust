import Benchmark
import Exhaust
import Foundation

func registerSynthesizedGeneratorBenchmarks() {
    let handWrittenGen = #gen(
        .asciiString(length: 1 ... 20),
        .uint(in: 0 ... 120),
        .bool(),
        .asciiString(length: 0 ... 50),
        .asciiString(length: 1 ... 30),
        .asciiString(length: 2 ... 5)
    ) { name, age, active, email, street, zip in
        BenchmarkPerson(
            name: name,
            age: age,
            active: active,
            email: email,
            address: BenchmarkAddress(street: street, zip: zip)
        )
    }

    let synthesizedGen: ReflectiveGenerator<BenchmarkPerson>
    do {
        synthesizedGen = try #gen(from: BenchmarkPerson(
            name: "Gaute",
            age: 30,
            active: true,
            email: "gaute@example.com",
            address: BenchmarkAddress(street: "123 Main St", zip: "90210")
        ))
    } catch {
        fatalError("Failed to synthesize benchmark generator: \(error)")
    }

    benchmark("Gen: HandWritten Person") {
        _ = #exhaust(
            handWrittenGen,
            .suppress(.issueReporting),
            .budget(.extensive),
            .replay(1337)
        ) { _ in true }
    }

    benchmark("Gen: Synthesized Person") {
        _ = #exhaust(
            synthesizedGen,
            .suppress(.issueReporting),
            .budget(.extensive),
            .replay(1337)
        ) { _ in true }
    }

    registerFlatStructBenchmarks()
}

// MARK: - Flat Struct (per-field overhead)

//
// BenchmarkPerson carries five top-level fields plus a nested struct, so its overhead mixes per-field replay cost with the nested level's second `init(from:)` pass.
// A flat struct with more primitive fields isolates the per-field cost — dictionary construction, leaf wrapping, and per-key decode dispatch — without that nesting.

private func registerFlatStructBenchmarks() {
    let handWrittenGen = #gen(
        .asciiString(length: 1 ... 20),
        .int(in: -1000 ... 1000),
        .uint(in: 0 ... 120),
        .bool(),
        .double(in: 0 ... 1),
        .asciiString(length: 0 ... 50),
        .int(in: 0 ... 1_000_000),
        .asciiString(length: 2 ... 5)
    ) { name, count, age, active, ratio, email, identifier, code in
        BenchmarkWideRecord(
            name: name,
            count: count,
            age: age,
            active: active,
            ratio: ratio,
            email: email,
            identifier: identifier,
            code: code
        )
    }

    let synthesizedGen: ReflectiveGenerator<BenchmarkWideRecord>
    do {
        synthesizedGen = try #gen(from: BenchmarkWideRecord(
            name: "Gaute",
            count: 42,
            age: 30,
            active: true,
            ratio: 0.5,
            email: "gaute@example.com",
            identifier: 999,
            code: "AB12"
        ))
    } catch {
        fatalError("Failed to synthesize flat benchmark generator: \(error)")
    }

    benchmark("Gen: HandWritten Flat") {
        _ = #exhaust(
            handWrittenGen,
            .suppress(.issueReporting),
            .budget(.extensive),
            .replay(1337)
        ) { _ in true }
    }

    benchmark("Gen: Synthesized Flat") {
        _ = #exhaust(
            synthesizedGen,
            .suppress(.issueReporting),
            .budget(.extensive),
            .replay(1337)
        ) { _ in true }
    }
}

// MARK: - Benchmark Types

struct BenchmarkAddress: Codable, Equatable {
    let street: String
    let zip: String
}

struct BenchmarkPerson: Codable, Equatable {
    let name: String
    let age: UInt
    let active: Bool
    let email: String
    let address: BenchmarkAddress
}

struct BenchmarkWideRecord: Codable, Equatable {
    let name: String
    let count: Int
    let age: UInt
    let active: Bool
    let ratio: Double
    let email: String
    let identifier: Int
    let code: String
}
