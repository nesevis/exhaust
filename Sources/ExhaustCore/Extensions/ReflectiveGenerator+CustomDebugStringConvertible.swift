//
//  ReflectiveGenerator+CustomDebugStringConvertible.swift
//  Exhaust
//
//  Created by Chris Kolbu on 12/12/2025.
//

extension ReflectiveGenerator: CustomDebugStringConvertible where Operation == ReflectiveOperation {
    /// Provides a human-readable tree view of the generator composition.
    ///
    /// This implementation shows the hierarchical structure of generator operations, making it easier to understand complex generator compositions, debug generation issues, and visualize how Choice Gradient Sampling optimizations are applied.
    ///
    /// Example output:
    /// ```
    /// ReflectiveGenerator<BinarySearchTree<Int>>
    /// └── pick(choices: 2)
    ///     ├── just(leaf)
    ///     └── zip(generators: 3)
    ///         ├── BinarySearchTree<Int>.arbitrary
    ///         ├── chooseBits(Int: -2147483648...2147483647)
    ///         └── BinarySearchTree<Int>.arbitrary
    /// ```
    public var debugDescription: String {
        let typeName = "\(Value.self)"
        return "ReflectiveGenerator<\(typeName)>\n" + treeDescription(prefix: "", isLast: true)
    }

    private func treeDescription(prefix: String, isLast: Bool, depth: Int = 0) -> String {
        // Prevent infinite recursion in self-referential generators
        guard depth < 15 else {
            let connector = isLast ? "└── " : "├── "
            return prefix + connector + "... (max depth reached)"
        }

        let connector = isLast ? "└── " : "├── "
        let childPrefix = prefix + (isLast ? "    " : "│   ")

        switch self {
        case let .pure(value):
            return prefix + connector + "pure(\(value))"

        case let .impure(operation, _):
            let operationDesc = operationDescription(
                operation,
                childPrefix: childPrefix,
                depth: depth + 1
            )
            return prefix + connector + operationDesc
        }
    }

    private func operationDescription(
        _ operation: ReflectiveOperation,
        childPrefix: String,
        depth: Int
    ) -> String {
        switch operation {
        case let .chooseBits(min, max, tag, isRangeExplicit, scaling):
            let range = formatBitRange(min: min, max: max, tag: tag)
            var suffix = isRangeExplicit ? "" : " [derived]"
            switch scaling {
            case .none: break
            case .some(.linear): suffix += " [linear]"
            case .some(.exponential): suffix += " [exponential]"
            }
            return "chooseBits(\(tag.description): \(range))\(suffix)"

        case let .pick(choices):
            let fingerprint = choices.first?.fingerprint ?? 0
            let fingerprintShort = String(format: "%08X", fingerprint & 0xFFFF_FFFF)
            let header = "pick(id: \(fingerprintShort), choices: \(choices.count))"
            if choices.isEmpty {
                return header
            }

            let childDescriptions = choices.enumerated().map { index, choice in
                let isLast = index == choices.count - 1
                let weightDesc = choice.weight > 0 ? " [weight: \(choice.weight)]" : " (pruned)"
                let choiceHeader = "choice\(weightDesc)"

                // Try to get meaningful description of the nested generator
                let nestedDesc = choice.generator.treeDescription(
                    prefix: childPrefix + (isLast ? "    " : "│   "),
                    isLast: true,
                    depth: depth + 1
                )

                let connector = isLast ? "└── " : "├── "
                return childPrefix + connector + choiceHeader
                    + "\n" + nestedDesc
            }

            return header + "\n" + childDescriptions.joined(separator: "\n")

        case let .zip(generators, _):
            let header = "zip(generators: \(generators.count))"
            if generators.isEmpty {
                return header
            }

            let childDescriptions = generators.enumerated().map { index, generator in
                let isLast = index == generators.count - 1
                return generator.treeDescription(
                    prefix: childPrefix,
                    isLast: isLast,
                    depth: depth + 1
                )
            }

            return header + "\n" + childDescriptions.joined(separator: "\n")

        case let .sequence(length, gen):
            let lengthDesc = length.treeDescription(
                prefix: childPrefix,
                isLast: false,
                depth: depth + 1
            )
            let genDesc = gen.treeDescription(prefix: childPrefix, isLast: true, depth: depth + 1)
            return "sequence\n" + lengthDesc + "\n" + genDesc

        case let .contramap(_, next):
            let nextDesc = next.treeDescription(prefix: childPrefix, isLast: true, depth: depth + 1)
            return "contramap\n" + nextDesc

        case let .prune(next):
            let nextDesc = next.treeDescription(prefix: childPrefix, isLast: true, depth: depth + 1)
            return "prune\n" + nextDesc

        case let .just(value):
            return "just(\(formatJustValue(value)))"

        case .getSize:
            return "getSize"

        case let .filter(gen, fingerprint, _, _):
            let fingerprintShort = String(format: "%08X", fingerprint & 0xFFFF_FFFF)
            let genDesc = gen.treeDescription(prefix: childPrefix, isLast: true, depth: depth + 1)
            return "filter(fingerprint: \(fingerprintShort))\n" + genDesc

        case let .resize(newSize, next):
            let nextDesc = next.treeDescription(prefix: childPrefix, isLast: true, depth: depth + 1)
            return "resize(size: \(newSize))\n" + nextDesc

        case let .classify(gen, fingerprint, classifiers):
            let fingerprintShort = String(format: "%08X", fingerprint & 0xFFFF_FFFF)
            let classifierLabels = classifiers.map(\.label).joined(separator: ", ")
            let genDesc = gen.treeDescription(
                prefix: childPrefix,
                isLast: true,
                depth: depth + 1
            )
            let header = "classify(fingerprint: \(fingerprintShort), labels: [\(classifierLabels)])"
            return header + "\n" + genDesc

        case let .unique(gen, fingerprint, keyExtractor):
            let fingerprintShort = String(format: "%08X", fingerprint & 0xFFFF_FFFF)
            let mode = keyExtractor != nil ? "by key" : "by choice sequence"
            let genDesc = gen.treeDescription(prefix: childPrefix, isLast: true, depth: depth + 1)
            return "unique(fingerprint: \(fingerprintShort), \(mode))\n" + genDesc

        case let .transform(kind, inner):
            let kindDesc: String
            switch kind {
            case let .map(_, inputType, outputType):
                kindDesc = "map: \(inputType) → \(outputType)"
            case let .bind(_, _, backward, inputType, outputType):
                let direction = backward != nil ? "bind↔" : "bind→"
                kindDesc = "\(direction): \(inputType) → \(outputType)"
            case let .metamorphic(transforms, inputType):
                kindDesc = "metamorphic(\(transforms.count)×): \(inputType)"
            }
            let innerDesc = inner.treeDescription(
                prefix: childPrefix,
                isLast: true,
                depth: depth + 1
            )
            return "transform(\(kindDesc))\n" + innerDesc
        }
    }

    private func formatBitRange(min: UInt64, max: UInt64, tag: TypeTag) -> String {
        let value = ChoiceValue(0, tag: tag)
        return value.displayRange(min ... max)
    }

    private func formatJustValue(_ value: Any) -> String {
        if let stringValue = value as? String {
            "\"\(stringValue)\""
        } else if let charValue = value as? Character {
            "\"\(charValue)\""
        } else {
            "\(value)"
        }
    }
}
