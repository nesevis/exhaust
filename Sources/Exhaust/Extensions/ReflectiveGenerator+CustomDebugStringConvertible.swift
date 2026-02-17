//
//  ReflectiveGenerator+CustomDebugStringConvertible.swift
//  Exhaust
//
//  Created by Chris Kolbu on 12/12/2025.
//

extension ReflectiveGenerator: CustomDebugStringConvertible where Operation == ReflectiveOperation {
    /// Provides a human-readable tree view of the generator composition.
    ///
    /// This implementation shows the hierarchical structure of generator operations,
    /// making it easier to understand complex generator compositions, debug generation
    /// issues, and visualize how Choice Gradient Sampling optimizations are applied.
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
            let operationDesc = operationDescription(operation, childPrefix: childPrefix, depth: depth + 1)
            return prefix + connector + operationDesc
        }
    }

    private func operationDescription(_ operation: ReflectiveOperation, childPrefix: String, depth: Int) -> String {
        switch operation {
        case let .chooseBits(min, max, tag):
            let range = formatBitRange(min: min, max: max, tag: tag)
            return "chooseBits(\(tag.description): \(range))"

        case let .pick(choices):
            let header = "pick(choices: \(choices.count))"
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

                return childPrefix + (isLast ? "└── " : "├── ") + choiceHeader + "\n" + nestedDesc
            }

            return header + "\n" + childDescriptions.joined(separator: "\n")

        case let .zip(generators):
            let header = "zip(generators: \(generators.count))"
            if generators.isEmpty {
                return header
            }

            let childDescriptions = generators.enumerated().map { index, generator in
                let isLast = index == generators.count - 1
                return generator.treeDescription(prefix: childPrefix, isLast: isLast, depth: depth + 1)
            }

            return header + "\n" + childDescriptions.joined(separator: "\n")

        case let .sequence(length, gen):
            let lengthDesc = length.treeDescription(prefix: childPrefix, isLast: false, depth: depth + 1)
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

        case let .filter(gen, fingerprint, _):
            let fingerprintShort = String(format: "%08X", fingerprint & 0xFFFF_FFFF)
            let genDesc = gen.treeDescription(prefix: childPrefix, isLast: true, depth: depth + 1)
            return "filter(fingerprint: \(fingerprintShort))\n" + genDesc

        case let .resize(newSize, next):
            let nextDesc = next.treeDescription(prefix: childPrefix, isLast: true, depth: depth + 1)
            return "resize(size: \(newSize))\n" + nextDesc

        case let .classify(gen, fingerprint, classifiers):
            let fingerprintShort = String(format: "%08X", fingerprint & 0xFFFF_FFFF)
            let classifierLabels = classifiers.map { $0.label }.joined(separator: ", ")
            let genDesc = gen.treeDescription(prefix: childPrefix, isLast: true, depth: depth + 1)
            return "classify(fingerprint: \(fingerprintShort), labels: [\(classifierLabels)])\n" + genDesc
        }
    }

    private func formatBitRange(min: UInt64, max: UInt64, tag: TypeTag) -> String {
        let value = ChoiceValue(0, tag: tag)
        return value.displayRange(min ... max)
//        switch tag {
//        case .int:
//        case .uint:
//            return "\(min)...\(max)"
//        case .uint64:
//            return "\(min)...\(max)"
//        case .float:
//            let minFloat = Float(bitPattern: UInt32(min))
//            let maxFloat = Float(bitPattern: UInt32(max))
//            return "\(minFloat)...\(maxFloat)"
//        case .double:
//            let minDouble = Double(bitPattern: min)
//            let maxDouble = Double(bitPattern: max)
//            return "\(minDouble)...\(maxDouble)"
//        case .character:
//            if min == max {
//                if let scalar = UnicodeScalar(UInt32(min)) {
//                    return "\"\(Character(scalar))\""
//                }
//            }
//            return "\\u{\(String(min, radix: 16))}...\\u{\(String(max, radix: 16))}"
//        case .uint8:
//            return "\(UInt8(min))...\(UInt8(max))"
//        case .uint16:
//            return "\(UInt16(min))...\(UInt16(max))"
//        case .uint32:
//            return "\(UInt32(min))...\(UInt32(max))"
//        case .int8:
//            let minInt8 = Int8(bitPattern: UInt8(min))
//            let maxInt8 = Int8(bitPattern: UInt8(max))
//            return "\(minInt8)...\(maxInt8)"
//        case .int16:
//            let minInt16 = Int16(bitPattern: UInt16(min))
//            let maxInt16 = Int16(bitPattern: UInt16(max))
//            return "\(minInt16)...\(maxInt16)"
//        case .int32:
//            let minInt32 = Int32(bitPattern: UInt32(min))
//            let maxInt32 = Int32(bitPattern: UInt32(max))
//            return "\(minInt32)...\(maxInt32)"
//        case .int64:
//            let minInt64 = Int64(bitPattern: min)
//            let maxInt64 = Int64(bitPattern: max)
//            return "\(minInt64)...\(maxInt64)"
//        }
    }

    private func formatJustValue(_ value: Any) -> String {
        if let stringValue = value as? String {
            return "\"\(stringValue)\""
        } else if let charValue = value as? Character {
            return "\"\(charValue)\""
        } else {
            return "\(value)"
        }
    }
}
