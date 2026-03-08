//
//  AdvancedCoupledScenariosTests.swift
//  ExhaustTests
//
//  Advanced and coupled shrinking scenarios inspired by fast-check, jqwik,
//  Hypothesis, and CsCheck challenge cases.
//

import ExhaustCore
import Testing
@testable import Exhaust

private enum AdvancedCoupledFixtures {
    enum StackAction: Equatable {
        case push(String)
        case pop
    }

    struct BuggyStack {
        private(set) var storage: [String] = []

        mutating func push(_ value: String) {
            // Intentional bug: pushes the same value twice.
            storage.append(value)
            storage.append(value)
        }

        mutating func pop() {
            guard storage.isEmpty == false else { return }
            storage.removeLast()
        }

        var count: Int {
            storage.count
        }
    }

    static func stackInvariantHolds(actions: [StackAction]) -> Bool {
        var stack = BuggyStack()
        var expectedCount = 0

        for action in actions {
            switch action {
            case let .push(value):
                stack.push(value)
                expectedCount += 1
            case .pop:
                stack.pop()
                if expectedCount > 0 {
                    expectedCount -= 1
                }
            }

            if stack.count != expectedCount {
                return false
            }
        }

        return true
    }

    static func buggyRLEEncode(_ s: String) -> [(Int, Character)] {
        guard let first = s.first else { return [] }

        var output: [(Int, Character)] = []
        var current = first
        var count = 1

        for character in s.dropFirst() {
            if character == current {
                count += 1
            } else {
                output.append((count, current))
                let previousRun = (count, current)
                current = character
                // Intentional regression: for a `00` run followed by `1`,
                // the next-run count is reset incorrectly.
                if previousRun.1 == "0", previousRun.0 == 2, character == "1" {
                    count = 0
                } else {
                    count = 1
                }
            }
        }

        output.append((count, current))
        return output
    }

    static func rleDecode(_ encoded: [(Int, Character)]) -> String {
        var chars: [Character] = []
        for (count, character) in encoded where count > 0 {
            chars.append(contentsOf: repeatElement(character, count: count))
        }
        return String(chars)
    }
}

@Suite("Advanced & Coupled Scenarios")
struct AdvancedCoupledScenariosTests {
    private func reduce<Output>(
        _ gen: ReflectiveGenerator<Output>,
        startingAt value: Output,
        config: Interpreters.TCRConfiguration = .fast,
        property: (Output) -> Bool,
    ) throws -> Output {
        let tree = try #require(try Interpreters.reflect(gen, with: value))
        let (_, output) = try #require(
            try Interpreters.reduce(gen: gen, tree: tree, config: config, property: property),
        )
        return output
    }

    @Test("2.1 Coupled Integers (fast-check)")
    func coupledIntegersFastCheckStyle() throws {
        let gen = #gen(
            .int(in: 0 ... 1_000_000),
            .int(in: 0 ... 1_000_000),
        )

        let property: ((Int, Int)) -> Bool = { pair in
            let a = pair.0
            let b = pair.1
            if a < 1000 { return true }
            if b < 1000 { return true }
            if b < a { return true }
            if abs(a - b) < 10 { return true }
            return b - a >= 1000
        }

        let output = try reduce(
            gen,
            startingAt: (500_000, 500_500),
            property: property,
        )

        #expect(property(output) == false)
        #expect(output == (1000, 1010))
    }

    @Test("2.2 Stateful Stack Bug (jqwik)")
    func statefulStackBugJqwikStyle() throws {
        let actionGen: ReflectiveGenerator<AdvancedCoupledFixtures.StackAction> = #gen(
            .int(in: 0 ... 1),
            Gen.element(from: ["a", "b", "c"]),
        )
        .mapped(
            forward: { tag, value in
                tag == 0 ? .pop : .push(value)
            },
            backward: { action in
                switch action {
                case .pop:
                    (0, "a")
                case let .push(value):
                    (1, value)
                }
            },
        )

        let gen = actionGen.array(length: 1 ... 40)
        let property: ([AdvancedCoupledFixtures.StackAction]) -> Bool = { actions in
            AdvancedCoupledFixtures.stackInvariantHolds(actions: actions)
        }

        let output = try reduce(
            gen,
            startingAt: [.push("c"), .pop, .push("b")],
            property: property,
        )

        #expect(property(output) == false)
        #expect(output == [.push("a")])
    }

    @Test("2.3 Run-Length Encoding Regression (Hypothesis)")
    func runLengthEncodingRegressionHypothesisStyle() throws {
        let binaryStringGen = Gen.element(from: Array("01"))
            .array(length: 0 ... 40)
            .mapped(
                forward: { chars in String(chars) },
                backward: { string in Array(string) },
            )

        let property: (String) -> Bool = { s in
            AdvancedCoupledFixtures.rleDecode(AdvancedCoupledFixtures.buggyRLEEncode(s)) == s
        }

        let output = try reduce(
            binaryStringGen,
            startingAt: "11001",
            property: property,
        )

        #expect(property(output) == false)
        #expect(output == "001")
    }

    @Test("2.4 Floating Point Summation (Hypothesis)")
    func floatingPointSummationHypothesisStyle() throws {
        let gen = #gen(
            .double(in: 0.0 ... 1000.0),
            .double(in: 0.0 ... 1000.0),
        )

        let property: ((Double, Double)) -> Bool = { pair in
            pair.0 + pair.1 <= 1000.0
        }

        let output = try reduce(
            gen,
            startingAt: (700.25, 450.75),
            property: property,
        )

        #expect(property(output) == false)
        #expect(output.1 == 1000.0)
        #expect(output.0 == 1.0 || output.0 == Double.ulpOfOne)
    }

    @Test("2.5 Nasty Strings (Hypothesis)")
    func nastyUnicodeStringsHypothesisStyle() throws {
        let marker = "𝕿𝖍𝖊"
        let unicodeStringGen = Gen.element(from: Array("xy The𝕿𝖍𝖊"))
            .array(length: 0 ... 40)
            .mapped(
                forward: { chars in String(chars) },
                backward: { string in Array(string) },
            )

        let property: (String) -> Bool = { s in
            s.contains(marker) == false
        }

        let output = try reduce(
            unicodeStringGen,
            startingAt: "xx\(marker)yy",
            property: property,
        )

        #expect(property(output) == false)
        #expect(output == marker)
    }

    @Test("2.6 Difference with Gap (CsCheck)")
    func differenceWithGapCsCheckStyle() throws {
        let gen = #gen(
            .int(in: 0 ... 1_000_000),
            .int(in: 0 ... 1_000_000),
        )

        let property: ((Int, Int)) -> Bool = { pair in
            let a = pair.0
            let b = pair.1
            return a < 10 || abs(a - b) > 4 || a == b
        }

        let output = try reduce(
            gen,
            startingAt: (700, 702),
            property: property,
        )

        #expect(property(output) == false)
        #expect(output == (10, 6) || output == (10, 14))
    }
}
