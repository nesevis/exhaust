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
