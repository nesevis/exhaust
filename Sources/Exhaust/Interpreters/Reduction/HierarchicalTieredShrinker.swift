//
//  HierarchicalTieredShrinker.swift
//  Exhaust
//
//  Created by Chris Kolbu on 21/7/2025.
//

final class HierarchicalTieredShrinker: IteratorProtocol {
    typealias Element = ChoiceTree
    typealias Shrinks = [ChoiceTree].SubSequence
    private typealias Shrink = (ChoiceTree?, State)
    
    /// The original candidate
    private var origin: ChoiceTree
    private var isImportant: Bool
    
    /// The internal state of the iterator
    private var state: State
    
    init(_ candidate: ChoiceTree) {
        print("New shrinker iterator \(candidate.elementDescription)\n\(candidate.effectiveRange?.description ?? "No range")")
        self.origin = candidate
        self.isImportant = candidate.isImportant
        self.state = .idle
    }
    
    private enum State {
        case idle
        case exhausted
        
        /// Representing a ChoiceTree.choice
        case choice(shrinks: Shrinks, metadata: ChoiceMetadata, strategy: [any TemporaryDualPurposeStrategy])

        /// Representing a ChoiceTree.sequence
        case sequence(shrinks: Shrinks, original: Shrinks, metadata: ChoiceMetadata, strategy: [any TemporaryDualPurposeStrategy])
        
        /// Representing the element of a ChoiceTree.sequence. `shrinks` is presented as a subsequence, but is never sliced beyond its original size
        case element(shrinks: Shrinks, childIndex: Int, subIterator: HierarchicalTieredShrinker, sequenceMetadata: ChoiceMetadata, sequenceStrategy: [any TemporaryDualPurposeStrategy])
        
        /// Representing a group that is being shrunk
        case group(children: Shrinks, childIndex: Int, subIterators: [HierarchicalTieredShrinker], exhaustedChildren: Set<Int>)
        
        /// Representing a branch in the ``ChoiceTree``
        case branch(label: UInt64, children: Shrinks, childIndex: Int, subIterators: [HierarchicalTieredShrinker], exhaustedChildren: Set<Int>)
    }
    
    /// This kicks off the initial round of shrinks. It will go by strategy
    private func handle(first: ChoiceTree) -> Shrink {
        switch first {
        case let .choice(_, meta):
            // If the first strategy is a no go, this returns early
            let shrinks = self.shrinks(for: first, strategies: meta.strategies)
            guard let first = shrinks.first else {
                return (nil, .exhausted)
            }
            return (first, .choice(shrinks: shrinks.dropFirst(), metadata: meta, strategy: first.strategy))
        case .just:
            return (nil, .exhausted)
        case let .sequence(_, _, meta):
            let shrinks = self.shrinks(for: first, strategies: meta.strategies)
            guard let first = shrinks.first else {
                return (nil, .exhausted)
            }
            return (first, .sequence(shrinks: shrinks.dropFirst(), original: shrinks, metadata: meta, strategy: first.strategy))
        case let .branch(label, array):
            guard let firstBranch = array.first else {
                return (nil, .exhausted)
            }
            // This doesn't property wrap up the value again
            let subIterators = array.map { HierarchicalTieredShrinker($0) }
            return (first, .branch(label: label, children: array[...], childIndex: 0, subIterators: subIterators, exhaustedChildren: []))
        case let .group(array):
            //
            guard array.isEmpty == false else {
                return (nil, .exhausted)
            }
            let subIterators = array.map { HierarchicalTieredShrinker($0) }
            // We should be returning a group here.
            return (first, .group(children: array[...], childIndex: 0, subIterators: subIterators, exhaustedChildren: []))
        case let .important(value):
            return handle(first: value)
        case .selected:
            fatalError("\(Self.self) should not handle `.selected`")
        }
    }
    
    private func shrinks(for path: ChoiceTree, strategies: [any TemporaryDualPurposeStrategy]) -> Shrinks {
        var shrinks: Shrinks?
        var remaining = strategies
        while remaining.isEmpty == false, (shrinks?.isEmpty ?? true) {
            let current = remaining.removeFirst()
            switch path {
            case .choice(let choiceValue, let choiceMetadata):
                let rawRange = choiceMetadata.validRanges[0]
                switch choiceValue {
                case .unsigned(let uint):
                    shrinks = current.values(for: uint, in: rawRange)
                        .map { ChoiceTree.choice(ChoiceValue($0), choiceMetadata).with(strategies: remaining) }[...]
                case .signed(let int, _):
                    let castRange = Int64(bitPattern64: rawRange.lowerBound)...Int64(bitPattern64: rawRange.upperBound)
                    shrinks = current.values(for: int, in: castRange)
                        .map { ChoiceTree.choice(ChoiceValue($0), choiceMetadata).with(strategies: remaining) }[...]
                case .floating(let double, _):
                    let castRange = Double(bitPattern64: rawRange.lowerBound)...Double(bitPattern64: rawRange.upperBound)
                    shrinks = current.values(for: double, in: castRange)
                        .map { ChoiceTree.choice(ChoiceValue($0), choiceMetadata).with(strategies: remaining) }[...]
                case .character(let character):
                    let castRanges = choiceMetadata.validRanges.map { range in
                        Character(bitPattern64: range.lowerBound)...Character(bitPattern64: range.upperBound)
                    }
                    shrinks = current.values(for: character, in: castRanges)
                        .map { ChoiceTree.choice(.character($0), choiceMetadata).with(strategies: remaining) }[...]
                }
            case .sequence(_, let elements, let choiceMetadata):
                let rawRange = choiceMetadata.validRanges[0]
                let castRange = Int(bitPattern64: rawRange.lowerBound)...Int(bitPattern64: rawRange.upperBound)
                let results = current.values(for: elements, in: castRange)
                shrinks = results
                    .filter { $0.isEmpty == false }
                    .map { collection in
                        .sequence(
                            length: UInt64(results.count),
                            elements: Array(collection as! Shrinks),
                            choiceMetadata
                        ).with(strategies: remaining)
                }[...]
            case .important(let choiceTree):
                // FIXME: This feels suboptimal
                return self.shrinks(for: choiceTree, strategies: [current])
            default:
                fatalError("\(#function) can't be called with \(path)")
            }
        }
        return shrinks ?? [][...]
    }
    
    // MARK: - IteratorProtocol
    
    func next() -> ChoiceTree? {
        // Sequences will sometimes defer their work to the next cycle, so this is wrapped in a while
        while true {
            switch state {
            case .idle:
                let (result, state) = self.handle(first: origin)
                self.state = state
                if case .group = result {
                    continue
                }
                if let result {
                    if isImportant {
                        return .important(result)
                    }
                    if result.isJust {
                        // What?
//                        return nil
                    }
                    return result
                }
                continue
            case .exhausted:
                return nil
            case let .sequence(shrinks, original, meta, strategy):
                if let result = shrinks.first {
//                    print("Sequence continuing strategy for:\n \(result)")
                    // We still have shrinks left in this sequence strategy
                    self.state = .sequence(shrinks: shrinks.dropFirst(), original: original, metadata: meta, strategy: strategy)
                    if isImportant {
                        return .important(result)
                    }
                    return result
                }
                if origin.isImportant {
                    state = .exhausted
                    return nil
                }
                // Try the next strategies with the original input
                let new = origin.with(strategies: strategy)
                let (result, state) = self.handle(first: new)
                if let result {
                    // We still have other sequence strategies to try
//                    print("Sequence switching strategy for:\n \(result)")
                    self.state = state
                    if isImportant {
                        return .important(result)
                    }
                    return result
                }
                // Strategies are exhausted; move on to the children
                // These are all the elements. We keep all the strategies from `origin` intact
                let children = new.children
                if let first = children.first {
                    self.state = .element(
                        shrinks: children[...],
                        childIndex: 0,
                        subIterator: .init(first),
                        // This is interesting. These should belong to the child?
                        sequenceMetadata: origin.metadata,
                        sequenceStrategy: origin.strategy
                    )
                    continue
                }
                // Children are exhausted; go home
                self.state = .exhausted
                return nil
                
            case .element(var shrinks, var index, let subIterator, let sequenceMetadata, let sequenceStrategy):
                // Try to get a shrink for this element
                if let subResult = subIterator.next() {
                    // Success! We got a smaller version of the element.
//                    print("Element continuing strategy for index \(index):\n \(subResult)")
                    shrinks[index] = subResult
                    state = .element(
                        shrinks: shrinks,
                        childIndex: index,
                        subIterator: subIterator,
                        sequenceMetadata: sequenceMetadata,
                        sequenceStrategy: sequenceStrategy
                    )
                    // We return a sequence here, so it's important that the metadata is that of the sequence
                    return .sequence(
                        length: UInt64(shrinks.count),
                        elements: Array(shrinks),
                        sequenceMetadata
                    )
                } else {
                    // The iterator for the current element is exhausted. Move to the next one.
                    index += 1
                    if (index >= shrinks.count) {
                        // We're done
//                        print("Element shrink completed")
                        state = .exhausted
                        return nil
                    }
                    // Shrink the next element
                    state = .element(
                        shrinks: shrinks,
                        childIndex: index,
                        subIterator: HierarchicalTieredShrinker(shrinks[index]),
                        sequenceMetadata: sequenceMetadata,
                        sequenceStrategy: sequenceStrategy
                    )
                    continue
                }
            case let .choice(shrinks, meta, strategy):
                guard let result = shrinks.first else {
                    // Go to the next strategy, if available
                    let (result, state) = self.handle(first: origin.with(strategies: strategy))
                    if let result {
//                        print("Choice switching strategy for:\n \(result)")
                        self.state = state
                        if isImportant {
                            return .important(result)
                        }
                        return result
                    }
//                    print("Choice exhausted")
                    self.state = .exhausted
                    return nil
                }
//                print("Choice continuing strategy for:\n \(result)")
                self.state = .choice(shrinks: shrinks.dropFirst(), metadata: meta, strategy: strategy)
                return result
            case .group(var children, var index, let subIterators, var exhaustedChildren):
                if let subResult = subIterators[index].next() {
                    children[index] = subResult
                    // There's still a result, update the child, and if it's not an important part, move to the next one (round-robin)
                    index = children[index].isImportant ? index : (index + 1) % children.count
                    // Skip exhausted children
                    while exhaustedChildren.contains(index) && exhaustedChildren.count < children.count {
                        index = (index + 1) % children.count
                    }
                    if exhaustedChildren.count >= children.count {
                        state = .exhausted
                        return nil
                    }
                    state = .group(children: children, childIndex: index, subIterators: subIterators, exhaustedChildren: exhaustedChildren)
                    return ChoiceTree.group(Array(children))
                } else {
                    // This child is exhausted, mark it and move to next
                    exhaustedChildren.insert(index)
                    if exhaustedChildren.count >= children.count {
                        state = .exhausted
                        return nil
                    }
                    index = (index + 1) % children.count
                    // Skip exhausted children
                    while exhaustedChildren.contains(index) {
                        index = (index + 1) % children.count
                    }
                    state = .group(children: children, childIndex: index, subIterators: subIterators, exhaustedChildren: exhaustedChildren)
                    continue
                }
            case .branch(let label, var children, var index, let subIterators, var exhaustedChildren):
                if let subResult = subIterators[index].next() {
                    children[index] = subResult
                    // There's still a result, update the child, and if it's not an important part, move to the next one (round-robin)
                    index = children[index].isImportant ? index : (index + 1) % children.count
                    // Skip exhausted children
                    while exhaustedChildren.contains(index) && exhaustedChildren.count < children.count {
                        index = (index + 1) % children.count
                    }
                    if exhaustedChildren.count >= children.count {
                        state = .exhausted
                        return nil
                    }
                    state = .branch(label: label, children: children, childIndex: index, subIterators: subIterators, exhaustedChildren: exhaustedChildren)
                    return ChoiceTree.branch(label: label, children: Array(children))
                } else {
                    // This child is exhausted, mark it and move to next
                    exhaustedChildren.insert(index)
                    if exhaustedChildren.count >= children.count {
                        state = .exhausted
                        return nil
                    }
                    index = (index + 1) % children.count
                    // Skip exhausted children
                    while exhaustedChildren.contains(index) {
                        index = (index + 1) % children.count
                    }
                    state = .branch(label: label, children: children, childIndex: index, subIterators: subIterators, exhaustedChildren: exhaustedChildren)
                    continue
                }
            }
        }
    }
}

extension ChoiceTree {
    var metadata: ChoiceMetadata {
        switch self {
        case let .choice(_, meta), let .sequence(_, _, meta):
            return meta
        default:
            return ChoiceMetadata(validRanges: [], strategies: [])
        }
    }
    
    var strategy: [any TemporaryDualPurposeStrategy] {
        self.metadata.strategies
    }
    
    func with(strategies: [any TemporaryDualPurposeStrategy]) -> ChoiceTree {
        switch self {
        case let .choice(value, meta):
            let newMeta = ChoiceMetadata(validRanges: meta.validRanges, strategies: strategies)
            return .choice(value, newMeta)
        case let .sequence(length, elements, meta):
            let newMeta = ChoiceMetadata(validRanges: meta.validRanges, strategies: strategies)
            return .sequence(length: length, elements: elements, newMeta)
        case let .important(value):
            return .important(value.with(strategies: strategies))
        default:
            fatalError("\(#function) should not be accessed directly by \(self)")
        }
    }
}


