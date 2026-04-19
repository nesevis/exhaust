//
//  ChoiceTreeVisualizationTests.swift
//  Exhaust
//

import ExhaustCore
import Testing

@Suite("ChoiceTree Visualization")
struct ChoiceTreeVisualizationTests {
    private let meta100 = ChoiceMetadata(validRange: 0 ... 100)
    private let meta256 = ChoiceMetadata(validRange: 0 ... 255)

    @Test("Single choice renders centered symbol")
    func singleChoice() {
        let tree = ChoiceTree.choice(.unsigned(42, .uint), meta100)
        let result = tree.visualization(width: 20)
        // 42/100 = 0.42, in [0.25, 0.75) → high tier → ◎
        #expect(result.contains("✳"))
        #expect(result.trimmingCharacters(in: .whitespaces) == "✳")
    }

    @Test("Single just renders centered diamond")
    func singleJust() {
        let tree = ChoiceTree.just
        let result = tree.visualization(width: 20)
        #expect(result.contains("✿"))
    }

    @Test("Zero value renders minimal dot")
    func zeroIsMinimal() {
        let tree = ChoiceTree.choice(.unsigned(0, .uint), meta100)
        let result = tree.visualization(width: 20)
        #expect(result.contains("·"))
    }

    @Test("Max value renders extreme circle")
    func maxIsExtreme() {
        let tree = ChoiceTree.choice(.unsigned(100, .uint), meta100)
        let result = tree.visualization(width: 20)
        #expect(result.contains("❋"))
    }

    @Test("Two choices produce diagonal connectors")
    func twoChoices() {
        let tree = ChoiceTree.group([
            .choice(.unsigned(0, .uint), meta100),
            .choice(.unsigned(50, .uint), meta100),
        ])
        let result = tree.visualization(width: 40)
        print("--- Two choices ---")
        print(result)
        // 0 → minimal (·), 50/100=0.5 → high (◎)
        #expect(result.contains("·"))
        #expect(result.contains("✳"))
    }

    @Test("Three choices produce box-drawing connectors")
    func threeChoices() {
        let tree = ChoiceTree.group([
            .choice(.unsigned(5, .uint), meta100),
            .choice(.unsigned(0, .uint), meta100),
            .choice(.unsigned(95, .uint), meta100),
        ])
        let result = tree.visualization(width: 40)
        print("--- Three choices ---")
        print(result)
        // Should use box-drawing with rounded corners for 3+ children
        #expect(result.contains("╰") || result.contains("╯") || result.contains("┴"))
    }

    @Test("Nested groups produce multi-level tree")
    func nestedGroups() {
        let tree = ChoiceTree.group([
            .choice(.unsigned(5, .uint), meta100),
            .group([
                .choice(.unsigned(42, .uint), meta100),
                .choice(.unsigned(0, .uint), meta100),
            ]),
        ])
        let result = tree.visualization(width: 40)
        print("--- Nested group ---")
        print(result)
        let lines = result.split(separator: "\n")
        // Multi-level tree should have at least 3 lines
        #expect(lines.count >= 3)
    }

    @Test("Selected wrapper is transparent")
    func selectedTransparent() {
        let inner = ChoiceTree.choice(.unsigned(42, .uint), meta100)
        let selected = ChoiceTree.selected(inner)
        let resultInner = inner.visualization(width: 20)
        let resultSelected = selected.visualization(width: 20)
        #expect(resultInner == resultSelected)
    }

    @Test("Bind with getSize collapses to visible children")
    func bindWithGetSize() {
        let tree = ChoiceTree.bind(
            fingerprint: 0,
            inner: .getSize(42),
            bound: .group([
                .choice(.unsigned(5, .uint), meta100),
                .choice(.unsigned(0, .uint), meta100),
            ])
        )
        let result = tree.visualization(width: 40)
        print("--- Bind with getSize ---")
        print(result)
        #expect(result.contains("·"))
    }

    @Test("Sequence elements render as children")
    func sequenceElements() {
        let tree = ChoiceTree.sequence(
            length: 3,
            elements: [
                .choice(.unsigned(0, .uint), meta256),
                .choice(.unsigned(128, .uint), meta256),
                .choice(.unsigned(255, .uint), meta256),
            ],
            meta256
        )
        let result = tree.visualization(width: 40)
        print("--- Sequence ---")
        print(result)
        // All three elements should be visible
        #expect(result.contains("·"))
        #expect(result.contains("❋"))
    }

    @Test("Deep tree with two groups")
    func deepTree() {
        let tree = ChoiceTree.group([
            .group([
                .choice(.unsigned(10, .uint), meta100),
                .choice(.unsigned(20, .uint), meta100),
            ]),
            .group([
                .choice(.unsigned(80, .uint), meta100),
                .choice(.unsigned(0, .uint), meta100),
                .choice(.unsigned(99, .uint), meta100),
            ]),
        ])
        let result = tree.visualization(width: 60)
        print("--- Deep tree ---")
        print(result)
        let lines = result.split(separator: "\n")
        // Should have multiple levels
        #expect(lines.count >= 5)
    }

    @Test("Deep tree with three groups")
    func deepTree3() {
        let tree = ChoiceTree.group([
            .group([
                .choice(.unsigned(10, .uint), meta100),
                .choice(.unsigned(20, .uint), meta100),
            ]),
            .group([
                .choice(.unsigned(80, .uint), meta100),
                .choice(.unsigned(0, .uint), meta100),
                .choice(.unsigned(99, .uint), meta100),
            ]),
            .group([
                .choice(.unsigned(0, .uint), meta100),
                .choice(.unsigned(10, .uint), meta100),
                .choice(.unsigned(20, .uint), meta100),
                .choice(.unsigned(50, .uint), meta100),
                .choice(.unsigned(90, .uint), meta100),
            ]),
        ])
        let result = tree.visualization(width: 60)
        print("--- Deep tree ---")
        print(result)
        let lines = result.split(separator: "\n")
        // Should have multiple levels
        #expect(lines.count >= 5)
    }

    @Test("Width parameter controls centering")
    func widthCentering() {
        let tree = ChoiceTree.choice(.unsigned(0, .uint), meta100)
        let narrow = tree.visualization(width: 10)
        let wide = tree.visualization(width: 40)
        // Wide should have more leading spaces
        let narrowPadding = narrow.prefix(while: { $0 == " " }).count
        let widePadding = wide.prefix(while: { $0 == " " }).count
        #expect(widePadding > narrowPadding)
    }

    @Test("Empty tree renders default symbol")
    func emptyTree() {
        let tree = ChoiceTree.getSize(42)
        let result = tree.visualization(width: 20)
        #expect(result.contains("·"))
    }

    @Test("Wide tree with five children")
    func wideTree() {
        let tree = ChoiceTree.group([
            .choice(.unsigned(0, .uint), meta100),
            .choice(.unsigned(10, .uint), meta100),
            .choice(.unsigned(20, .uint), meta100),
            .choice(.unsigned(50, .uint), meta100),
            .choice(.unsigned(90, .uint), meta100),
        ])
        let result = tree.visualization(width: 50)
        print("--- Wide (5 children) ---")
        print(result)
        #expect(result.contains("·"))
    }

    @Test("Bar endpoints align with leaves above")
    func barEndpointsAlignWithLeaves() {
        // Build a wide tree that triggers scaling
        let meta = ChoiceMetadata(validRange: 0 ... 100)
        let makeGroup: ([UInt64]) -> ChoiceTree = { values in
            .group(values.map { .choice(.unsigned($0, .uint), meta) })
        }
        let tree = ChoiceTree.group([
            makeGroup([10, 20, 30, 40]),
            makeGroup([50, 60, 70]),
            makeGroup([80, 90, 5, 15]),
            makeGroup([25, 35, 45]),
        ])
        let result = tree.visualization(width: 80)
        let lines = result.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        print("--- Wide alignment check ---")
        for (index, line) in lines.enumerated() {
            print("Row \(index): |\(line)|")
        }

        // Check: every ╰ and ╯ on a bar row should have a non-space character
        // directly above it (a leaf symbol or another connector)
        for row in 1 ..< lines.count {
            let line = Array(lines[row])
            let above = row > 0 ? Array(lines[row - 1]) : []
            for (col, char) in line.enumerated() where char == "╰" || char == "╯" {
                let aboveChar = col < above.count ? above[col] : Character(" ")
                if aboveChar == " " {
                    Issue.record("Bar endpoint '\(char)' at row \(row), col \(col) has nothing above it (expected leaf)")
                }
            }
        }
    }
}
