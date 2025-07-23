//
//  HierarchicalTieredShrinker.swift
//  Exhaust
//
//  Created by Chris Kolbu on 21/7/2025.
//

final class HierarchicalTieredShrinker: IteratorProtocol, Equatable {
    typealias Element = ChoiceTree
    typealias Shrinks = [ChoiceTree].SubSequence
    private typealias Shrink = (ChoiceTree?, State)
    
    /// The original candidate
    private var origin: ChoiceTree
    private var isImportant: Bool
    
    /// The internal state of the iterator
    private var state = State.idle
    
    init(_ candidate: ChoiceTree) {
        print("Creating new \( candidate.isImportant ? "important " : "")shrinker for\n\(candidate)\nMeta: \(candidate.metadata)")
        self.origin = candidate
        self.isImportant = candidate.isImportant
    }
    
    private enum State: Equatable {
        case idle
        case exhausted
        
        /// Representing a ChoiceTree.choice
        case choice(shrinks: Shrinks, metadata: ChoiceMetadata, strategy: [ShrinkingStrategy])

        /// Representing a ChoiceTree.sequence
        case sequence(shrinks: Shrinks, original: Shrinks, metadata: ChoiceMetadata, strategy: [ShrinkingStrategy])
        
        /// Representing the element of a ChoiceTree.sequence. `shrinks` is presented as a subsequence, but is never sliced beyond its original size
        case element(shrinks: Shrinks, childIndex: Int, subIterator: HierarchicalTieredShrinker, sequenceMetadata: ChoiceMetadata, sequenceStrategy: [ShrinkingStrategy])
        
        /// Representing a group that is being shrunk
        case group(children: Shrinks, childIndex: Int, subIterators: [HierarchicalTieredShrinker], exhaustedChildren: Set<Int>)
        
        /// Representing a branch in the ``ChoiceTree``
        case branch(label: UInt64, children: Shrinks, subIterator: HierarchicalTieredShrinker)
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
            guard let first = array.first else {
                return (nil, .exhausted)
            }
            let subIterator = HierarchicalTieredShrinker(first)
            return (first, .branch(label: label, children: array[...], subIterator: subIterator))
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
        }
    }
    
    private func shrinks(for path: ChoiceTree, strategies: [ShrinkingStrategy]) -> Shrinks {
        var shrinks: Shrinks?
        var remaining = strategies
        while remaining.isEmpty == false, (shrinks?.isEmpty ?? true) {
            let current = remaining.removeFirst()
            switch current {
            case .fundamentals:
                shrinks = path
                    .with(strategies: remaining)
                    .fundamentalValues[...]
            case .boundaries:
                shrinks = path
                    .with(strategies: remaining)
                    .boundaries[...]
            case .patterns:
                fatalError("\(current) is unsupported")
            case .binary:
                shrinks = path
                    .with(strategies: remaining)
                    .binary[...]
            case .decimal:
                fatalError("\(current) is unsupported")
            case .saturation:
                shrinks = path
                    .with(strategies: remaining)
                    .saturation[...]
            case .ultraSaturation:
                shrinks = path
                    .with(strategies: remaining)
                    .ultraSaturation[...]
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
            case let .branch(label, children, subIterator):
                if let subResult = subIterator.next() {
                    // There's still a result, keep working on the child
                    state = .branch(label: label, children: children, subIterator: subIterator)
                    return ChoiceTree.branch(label: label, children: CollectionOfOne(subResult) + Array(children))
                } else {
                    // We've exhausted this child
                    guard let child = children.first else {
                        state = .exhausted
                        return nil
                    }
                    let nextIterator = HierarchicalTieredShrinker(child)
                    state = .branch(label: label, children: children.dropFirst(), subIterator: nextIterator)
                    return ChoiceTree.branch(label: label, children: Array(children.dropFirst()))
                }
            }
        }
    }
    
    // MARK: - Equatable
    
    static func == (lhs: HierarchicalTieredShrinker, rhs: HierarchicalTieredShrinker) -> Bool {
        lhs.origin == rhs.origin &&
        lhs.state == rhs.state
    }
}

private extension ChoiceTree {
    var metadata: ChoiceMetadata {
        switch self {
        case let .choice(_, meta), let .sequence(_, _, meta):
            return meta
        default:
            return ChoiceMetadata(validRanges: [], strategies: [])
        }
    }
    
    var strategy: [ShrinkingStrategy] {
        self.metadata.strategies
    }
    
    func with(strategies: [ShrinkingStrategy]) -> ChoiceTree {
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


