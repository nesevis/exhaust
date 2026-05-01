import ExhaustCore

/// Produces a short natural language summary of what the reducer changed between the original failing example and the reduced counterexample.
///
/// Walks both values with `Mirror`, classifies each field as removed, simplified, or unchanged, and emits prose that foregrounds the interesting changes. Values at their semantic floor (nil, zero, false, empty) are treated as noise and suppressed from the "unchanged" category. When a reduced ``ChoiceSequence`` is provided, sequence length ranges are used for precise floor detection.
///
/// Returns `nil` when no meaningful summary can be produced.
func summarizeReduction<Value>(original: Value, reduced: Value, reducedSequence: ChoiceSequence? = nil) -> String? {
    let floors = reducedSequence.map(extractSequenceFloors) ?? []
    var collector = ReductionChangeCollector(sequenceFloors: floors)
    collector.walk(original, reduced, path: "")
    return collector.renderProse()
}

private func extractSequenceFloors(from sequence: ChoiceSequence) -> Set<UInt64> {
    var floors = Set<UInt64>()
    for entry in sequence {
        if case let .sequence(true, validRange: range, isLengthExplicit: _) = entry,
           let range {
            floors.insert(range.lowerBound)
        }
    }
    return floors
}

// MARK: - Change Collector

private struct ReductionChangeCollector {

    private let maxDepth = 3
    private let itemCap = 5

    private var removed: [String] = []
    private var simplified: [(path: String, from: String, to: String)] = []
    private var simplifiedToFloor: [String] = []
    private var collectionReductions: [(path: String, from: Int, to: Int, atGeneratorFloor: Bool)] = []
    private let sequenceFloors: Set<UInt64>
    private var dictionaryChanges: [DictionaryChange] = []
    private var unchangedNonTrivial: [(path: String, value: String)] = []
    private var visited = Set<ObjectIdentifier>()

    init(sequenceFloors: Set<UInt64> = []) {
        self.sequenceFloors = sequenceFloors
    }

    private struct DictionaryChange {
        let path: String
        let originalCount: Int
        let reducedCount: Int
        let removedKeys: [String]
        let addedKeys: [String]
        let survivedKeys: [String]
    }

    private func joinPath(_ base: String, _ component: String) -> String {
        if base.isEmpty { return component }
        if component.hasPrefix(".") { return "\(base)\(component)" }
        return "\(base).\(component)"
    }

    // MARK: Walk

    mutating func walk(_ original: Any, _ reduced: Any, path: String, depth: Int = 0) {
        if type(of: original) is AnyClass {
            let identifier = ObjectIdentifier(original as AnyObject)
            if visited.contains(identifier) { return }
            visited.insert(identifier)
        }

        let originalMirror = Mirror(reflecting: original)
        let reducedMirror = Mirror(reflecting: reduced)

        if originalMirror.displayStyle == .optional || reducedMirror.displayStyle == .optional {
            walkOptional(originalMirror, reducedMirror, path: path, depth: depth)
            return
        }

        if originalMirror.displayStyle == .collection && reducedMirror.displayStyle == .collection {
            let originalCount = originalMirror.children.count
            let reducedCount = reducedMirror.children.count
            let atFloor = mayBeAtGeneratorFloor(count: reducedCount)
            if originalCount != reducedCount {
                collectionReductions.append((path: path, from: originalCount, to: reducedCount, atGeneratorFloor: atFloor))
            }
            return
        }

        if originalMirror.displayStyle == .dictionary && reducedMirror.displayStyle == .dictionary {
            walkDictionary(originalMirror, reducedMirror, path: path, depth: depth)
            return
        }

        if originalMirror.displayStyle == .set && reducedMirror.displayStyle == .set {
            let originalCount = originalMirror.children.count
            let reducedCount = reducedMirror.children.count
            let atFloor = mayBeAtGeneratorFloor(count: reducedCount)
            if originalCount != reducedCount {
                collectionReductions.append((path: path, from: originalCount, to: reducedCount, atGeneratorFloor: atFloor))
            }
            return
        }

        if originalMirror.displayStyle == .enum && reducedMirror.displayStyle == .enum {
            walkEnum(original, reduced, originalMirror, reducedMirror, path: path, depth: depth)
            return
        }

        if originalMirror.displayStyle == .tuple && reducedMirror.displayStyle == .tuple {
            if depth < maxDepth {
                walkTuple(originalMirror, reducedMirror, path: path, depth: depth)
            }
            return
        }

        let hasChildren = { (mirror: Mirror) in
            (mirror.displayStyle == .struct || mirror.displayStyle == .class) && mirror.children.isEmpty == false
        }
        if hasChildren(originalMirror) && hasChildren(reducedMirror) && depth < maxDepth {
            walkCompound(originalMirror, reducedMirror, path: path, depth: depth)
            return
        }

        compareLeaves(original, reduced, path: path, depth: depth)
    }

    // MARK: Optional

    private mutating func walkOptional(
        _ originalMirror: Mirror, _ reducedMirror: Mirror,
        path: String, depth: Int
    ) {
        let originalValue = originalMirror.children.first?.value
        let reducedValue = reducedMirror.children.first?.value

        switch (originalValue, reducedValue) {
        case let (.some(original), .some(reduced)):
            walk(original, reduced, path: path, depth: depth)
        case (.some, .none):
            removed.append(path)
        default:
            break
        }
    }

    // MARK: Dictionary

    private mutating func walkDictionary(
        _ originalMirror: Mirror, _ reducedMirror: Mirror,
        path: String, depth: Int
    ) {
        let originalEntries = extractDictionaryEntries(originalMirror)
        let reducedEntries = extractDictionaryEntries(reducedMirror)

        let originalKeySet = Set(originalEntries.map(\.key))
        let reducedKeySet = Set(reducedEntries.map(\.key))

        let removedKeys = originalKeySet.subtracting(reducedKeySet).sorted()
        let addedKeys = reducedKeySet.subtracting(originalKeySet).sorted()
        let sharedKeys = originalKeySet.intersection(reducedKeySet).sorted()

        if removedKeys.isEmpty == false || addedKeys.isEmpty == false {
            dictionaryChanges.append(DictionaryChange(
                path: path,
                originalCount: originalEntries.count,
                reducedCount: reducedEntries.count,
                removedKeys: removedKeys,
                addedKeys: addedKeys,
                survivedKeys: sharedKeys
            ))
        }

        if depth + 1 < maxDepth {
            let originalByKey = Dictionary(
                originalEntries.map { ($0.key, $0.value) },
                uniquingKeysWith: { first, _ in first }
            )
            let reducedByKey = Dictionary(
                reducedEntries.map { ($0.key, $0.value) },
                uniquingKeysWith: { first, _ in first }
            )

            for key in sharedKeys {
                guard let originalValue = originalByKey[key],
                      let reducedValue = reducedByKey[key] else { continue }
                walk(originalValue, reducedValue, path: "\(path)[\"\(key)\"]", depth: depth + 1)
            }
        }
    }

    private func extractDictionaryEntries(_ mirror: Mirror) -> [(key: String, value: Any)] {
        mirror.children.compactMap { child in
            if let pair = child.value as? (key: AnyHashable, value: Any) {
                return (key: "\(pair.key)", value: pair.value)
            }
            let pairMirror = Mirror(reflecting: child.value)
            let children = Array(pairMirror.children)
            guard children.count >= 2 else { return nil }
            return (key: "\(children[0].value)", value: children[1].value)
        }
    }

    // MARK: Enum

    private mutating func walkEnum(
        _ original: Any, _ reduced: Any,
        _ originalMirror: Mirror, _ reducedMirror: Mirror,
        path: String, depth: Int
    ) {
        let originalCase = originalMirror.children.first
        let reducedCase = reducedMirror.children.first

        let originalLabel = originalCase?.label
        let reducedLabel = reducedCase?.label

        if let originalLabel, let reducedLabel, originalLabel == reducedLabel {
            let casePath = joinPath(path, originalLabel)
            walk(originalCase!.value, reducedCase!.value, path: casePath, depth: depth + 1)
        } else {
            let fromDesc = enumCaseName(original, originalMirror)
            let toDesc = enumCaseName(reduced, reducedMirror)
            if fromDesc != toDesc {
                simplified.append((path: path, from: fromDesc, to: toDesc))
            }
        }
    }

    private func enumCaseName(_ value: Any, _ mirror: Mirror) -> String {
        if let child = mirror.children.first {
            return ".\(child.label ?? "unknown")(\u{2026})"
        }
        return ".\(value)"
    }

    // MARK: Tuple

    private mutating func walkTuple(
        _ originalMirror: Mirror, _ reducedMirror: Mirror,
        path: String, depth: Int
    ) {
        let originalChildren = Array(originalMirror.children)
        let reducedChildren = Array(reducedMirror.children)

        for (index, (original, reduced)) in zip(originalChildren, reducedChildren).enumerated() {
            let label = original.label ?? ".\(index)"
            let childPath = joinPath(path, label)
            walk(original.value, reduced.value, path: childPath, depth: depth + 1)
        }
    }

    // MARK: Compound

    private mutating func walkCompound(
        _ originalMirror: Mirror, _ reducedMirror: Mirror,
        path: String, depth: Int
    ) {
        let originalChildren = collectChildren(originalMirror).filter(shouldInclude)
        let reducedChildren = collectChildren(reducedMirror).filter(shouldInclude)

        var reducedByLabel: [String: Any] = [:]
        for child in reducedChildren {
            if let label = child.label {
                reducedByLabel[label] = child.value
            }
        }

        for child in originalChildren {
            guard let label = child.label else { continue }
            let childPath = joinPath(path, label)

            guard let reducedValue = reducedByLabel[label] else {
                removed.append(childPath)
                continue
            }

            walk(child.value, reducedValue, path: childPath, depth: depth + 1)
        }
    }

    private func collectChildren(_ mirror: Mirror) -> [Mirror.Child] {
        var children = Array(mirror.children)
        var superMirror = mirror.superclassMirror
        while let current = superMirror {
            children.insert(contentsOf: current.children, at: 0)
            superMirror = current.superclassMirror
        }
        return children
    }

    // MARK: Sequence Floor

    private func mayBeAtGeneratorFloor(count: Int) -> Bool {
        sequenceFloors.contains(UInt64(count))
    }

    // MARK: Leaves

    private mutating func compareLeaves(_ original: Any, _ reduced: Any, path: String, depth: Int) {
        let originalDescription = briefDescription(original)
        let reducedDescription = briefDescription(reduced)

        if originalDescription == reducedDescription {
            if isAtFloor(reduced) == false && depth <= 2 {
                unchangedNonTrivial.append((path: path, value: reducedDescription))
            }
        } else if isAtFloor(reduced) {
            simplifiedToFloor.append(path)
        } else {
            simplified.append((path: path, from: originalDescription, to: reducedDescription))
        }
    }

    // MARK: Prose

    func renderProse() -> String? {
        let totalChanges = removed.count + simplified.count + simplifiedToFloor.count +
            collectionReductions.count + dictionaryChanges.count + unchangedNonTrivial.count

        if totalChanges == 0 { return nil }

        var sentences: [String] = []

        // Strongest signal: values that changed but stopped above floor
        if simplified.isEmpty == false {
            let items = simplified.prefix(itemCap).map { "\(backticked($0.path)) (\($0.from) \u{2192} \($0.to))" }
            let overflow = simplified.count > itemCap ? ", and \(simplified.count - itemCap) more" : ""
            sentences.append("- simplified but not to minimal value: \(items.joined(separator: ", "))\(overflow)")
        }

        // Strong signal: values identical in both original and reduced
        if unchangedNonTrivial.isEmpty == false {
            let items = unchangedNonTrivial.prefix(itemCap).map { "\(backticked($0.path)) (\($0.value))" }
            let overflow = unchangedNonTrivial.count > itemCap ? ", and \(unchangedNonTrivial.count - itemCap) more" : ""
            sentences.append("- survived reduction unchanged at non-minimal value: \(items.joined(separator: ", "))\(overflow)")
        }

        // Structural changes: dictionaries and collections
        for change in dictionaryChanges {
            let verb = change.reducedCount < change.originalCount ? "simplified" : "changed"
            var parts: [String] = [
                "\(backticked(change.path + ".count")) \(verb) (\(change.originalCount) \u{2192} \(change.reducedCount))"
            ]
            if change.removedKeys.isEmpty == false {
                parts.append("removed \(cappedNaturalList(change.removedKeys.map(quoted)))")
            }
            if change.addedKeys.isEmpty == false {
                parts.append("\(cappedNaturalList(change.addedKeys.map(quoted))) added")
            }
            if change.survivedKeys.isEmpty == false && (change.removedKeys.isEmpty == false || change.addedKeys.isEmpty == false) {
                parts.append("\(cappedNaturalList(change.survivedKeys.map(quoted))) survived")
            }
            sentences.append("- \(parts.joined(separator: "; "))")
        }

        for change in collectionReductions {
            if change.atGeneratorFloor {
                sentences.append("- \(backticked(change.path)) reduced from \(change.from) to \(change.to) elements (may be at generator minimum)")
            } else {
                sentences.append("- \(backticked(change.path)) reduced from \(change.from) to \(change.to) elements")
            }
        }

        // Removed fields
        if removed.isEmpty == false {
            sentences.append("- \(cappedNaturalList(removed.map(backticked))) removed")
        }

        // Weakest signal: values simplified all the way to floor
        if simplifiedToFloor.isEmpty == false {
            if simplifiedToFloor.count == 1 {
                sentences.append("- \(backticked(simplifiedToFloor[0])) simplified to its minimal value")
            } else {
                sentences.append("- \(cappedNaturalList(simplifiedToFloor.map(backticked))) simplified to minimal values")
            }
        }

        if sentences.isEmpty { return nil }
        return sentences.joined(separator: "\n")
    }

    private func cappedNaturalList(_ items: [String]) -> String {
        if items.count <= itemCap {
            return naturalList(items)
        }
        let shown = Array(items.prefix(itemCap))
        return "\(naturalList(shown)), and \(items.count - itemCap) more"
    }

    private func naturalList(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + ", and \(items.last!)"
        }
    }

    private func quoted(_ string: String) -> String {
        "\"\(string)\""
    }

    private func backticked(_ path: String) -> String {
        "`\(path)`"
    }
}

// MARK: - Helpers

private func shouldInclude(_ child: Mirror.Child) -> Bool {
    guard let label = child.label else { return false }
    if label.hasPrefix("$__lazy_storage_$_") { return false }
    if label.hasPrefix("_$") { return false }
    if "\(child.value)" == "(Function)" { return false }
    return true
}

// Very naive kludge for `semanticSimplest` given we are unable to correlate the ChoiceSequence with the positioning of the final values in the object
private func isAtFloor(_ value: Any) -> Bool {
    let mirror = Mirror(reflecting: value)

    if mirror.displayStyle == .optional {
        return mirror.children.isEmpty
    }

    if let bool = value as? Bool {
        return bool == false
    }

    if let string = value as? String {
        return string.isEmpty
    }

    if mirror.displayStyle == .collection || mirror.displayStyle == .set || mirror.displayStyle == .dictionary {
        return mirror.children.isEmpty
    }

    return "\(value)" == "0" || "\(value)" == "0.0"
}

private let descriptionCap = 60

private func briefDescription(_ value: Any) -> String {
    if let string = value as? String {
        if string.count > descriptionCap {
            return "\"\(string.prefix(descriptionCap))...\""
        }
        return "\"\(string)\""
    }

    let mirror = Mirror(reflecting: value)

    if mirror.displayStyle == .optional {
        if let child = mirror.children.first {
            return briefDescription(child.value)
        }
        return "nil"
    }

    if mirror.displayStyle == .enum {
        if let child = mirror.children.first {
            return ".\(child.label ?? "unknown")(...)"
        }
        return ".\(value)"
    }

    if mirror.displayStyle == .collection || mirror.displayStyle == .set {
        return "[\(mirror.children.count) elements]"
    }

    if mirror.displayStyle == .dictionary {
        return "[\(mirror.children.count) entries]"
    }

    if mirror.displayStyle == .struct || mirror.displayStyle == .class {
        return "\(type(of: value))(...)"
    }

    if mirror.displayStyle == .tuple {
        return "(\(mirror.children.count)-tuple)"
    }

    let description = "\(value)"
    if description.count > descriptionCap {
        return String(description.prefix(descriptionCap)) + "..."
    }
    return description
}
