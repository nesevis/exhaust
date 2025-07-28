//
//  HierarchicalTieredShrinker.swift
//  Exhaust
//
//  Created by Chris Kolbu on 21/7/2025.
//

final class ShrinkingIterator: IteratorProtocol {
    typealias Element = ChoiceTree
    typealias LazyShrinks = any AnyStrategyIterator
    typealias EagerShrinks = [ChoiceTree]
    private typealias Shrink = (ChoiceTree?, State)
    
    /// The original candidate
    private var origin: ChoiceTree
    private var isImportant: Bool
    
    /// The internal state of the iterator
    private var state: State
    
    init(_ candidate: ChoiceTree) {
//        print("New shrinker iterator \(candidate.elementDescription)\n\(candidate.effectiveRange?.description ?? "No range")")
        self.origin = candidate
        self.isImportant = candidate.isImportant
        self.state = .idle
    }
    
    private enum State {
        case idle
        case exhausted
        
        /// Representing a ChoiceTree.choice
        case choice(shrinks: LazyShrinks, metadata: ChoiceMetadata, strategy: [any TemporaryDualPurposeStrategy])

        /// Representing a ChoiceTree.sequence
        case sequence(shrinks: LazyShrinks, original: LazyShrinks, metadata: ChoiceMetadata, strategy: [any TemporaryDualPurposeStrategy])
        
        /// Representing the element of a ChoiceTree.sequence. `shrinks` is presented as a subsequence, but is never sliced beyond its original size
        case element(shrinks: EagerShrinks, childIndex: Int, subIterator: ShrinkingIterator, sequenceMetadata: ChoiceMetadata, sequenceStrategy: [any TemporaryDualPurposeStrategy])
        
        /// Representing a group that is being shrunk
        case group(children: EagerShrinks, childIndex: Int, subIterators: [ShrinkingIterator], exhaustedChildren: Set<Int>)
        
        /// Representing a branch in the ``ChoiceTree``
        case branch(label: UInt64, children: EagerShrinks, childIndex: Int, subIterators: [ShrinkingIterator], exhaustedChildren: Set<Int>)
        
        /// Representing a resize node with nested choices
        case resize(newSize: UInt64, choices: EagerShrinks, childIndex: Int, subIterators: [ShrinkingIterator], exhaustedChildren: Set<Int>)
    }
    
    /// This kicks off the initial round of shrinks. It will go by strategy
    private func handle(first: ChoiceTree) -> Shrink {
        switch first {
        case let .choice(_, meta):
            // If the first strategy is a no go, this returns early
            guard let shrinks = self.shrinks(for: first, strategies: meta.strategies), let first = shrinks.next() else {
                return (nil, .exhausted)
            }
            return (first, .choice(shrinks: shrinks, metadata: meta, strategy: first.strategy))
        case .just:
            return (nil, .exhausted)
        case let .sequence(_, _, meta):
            guard let shrinks = self.shrinks(for: first, strategies: meta.strategies), let first = shrinks.next() else {
                return (nil, .exhausted)
            }
            // FIXME: Don't materialise the sequence here
            return (first, .sequence(shrinks: shrinks, original: shrinks, metadata: meta, strategy: first.strategy))
        case let .branch(label, array):
            guard array.isEmpty == false else {
                return (nil, .exhausted)
            }
            // This doesn't property wrap up the value again
            let subIterators = array.map { ShrinkingIterator($0) }
            return (first, .branch(label: label, children: array, childIndex: 0, subIterators: subIterators, exhaustedChildren: []))
        case let .group(array):
            //
            guard array.isEmpty == false else {
                return (nil, .exhausted)
            }
            let subIterators = array.map { ShrinkingIterator($0) }
            // We should be returning a group here.
            return (first, .group(children: array, childIndex: 0, subIterators: subIterators, exhaustedChildren: []))
        case let .important(value):
            return handle(first: value)
        case .selected:
            fatalError("\(Self.self) should not handle `.selected`")
        case .getSize:
            // getSize nodes can't be shrunk, they represent constant size values
            return (nil, .exhausted)
        case let .resize(newSize, choices):
            // For resize nodes, shrink the nested choices
            guard !choices.isEmpty else {
                return (nil, .exhausted)
            }
            let subIterators = choices.map { ShrinkingIterator($0) }
            return (first, .resize(newSize: newSize, choices: choices, childIndex: 0, subIterators: subIterators, exhaustedChildren: []))
        }
    }
    
    private func shrinks(for path: ChoiceTree, strategies: [any TemporaryDualPurposeStrategy]) -> LazyShrinks? {
        var remaining = strategies
        while remaining.isEmpty == false {
            let current = remaining.removeFirst()
            switch path {
            case .choice(let choiceValue, let metadata):
                let rawRange = metadata.validRanges[0]
                switch choiceValue {
                case .unsigned(let uint):
                    return StrategyIterator(initial: uint, strategy: current, current.next(for:)) { next in
                        rawRange.contains(next)
                            ? ChoiceTree.choice(ChoiceValue(next), metadata).with(strategies: remaining)
                            : nil
                    }
                case .signed(let int, _):
                    let castRange = Int64(bitPattern64: rawRange.lowerBound)...Int64(bitPattern64: rawRange.upperBound)
                    return StrategyIterator(initial: int, strategy: current, current.next(for:)) { next in
                        castRange.contains(next)
                            ? ChoiceTree.choice(ChoiceValue(next), metadata).with(strategies: remaining)
                            : nil
                    }
                case .floating(let double, _):
                    let castRange = Double(bitPattern64: rawRange.lowerBound)...Double(bitPattern64: rawRange.upperBound)
                    return StrategyIterator(initial: double, strategy: current, current.next(for:)) { next in
                        castRange.contains(next)
                            ? ChoiceTree.choice(ChoiceValue(next), metadata).with(strategies: remaining)
                            : nil
                    }
                case .character(let character):
                    let castRanges = metadata.validRanges.map { range in
                        Character(bitPattern64: range.lowerBound)...Character(bitPattern64: range.upperBound)
                    }
                    return StrategyIterator(initial: character, strategy: current, current.next(for:)) { next in
                        castRanges.contains(where: { $0.contains(next) })
                            ? ChoiceTree.choice(ChoiceValue(next), metadata).with(strategies: remaining)
                            : nil
                    }
                }
            case .sequence(_, let elements, let metadata):
                let rawRange = metadata.validRanges[0]
                let castRange = Int(bitPattern64: rawRange.lowerBound)...Int(bitPattern64: rawRange.upperBound)
                
                guard elements.isEmpty == false else {
                    return nil
                }
                
                return StrategySequenceIterator(initial: elements, current.next(for:)) { values in
                    guard castRange.contains(values.count) else {
                        return nil
                    }
                    return ChoiceTree.sequence(length: UInt64(values.count), elements: Array(values), metadata).with(strategies: remaining)
                }
            case .important(let choiceTree):
                // FIXME: This feels suboptimal
                return self.shrinks(for: choiceTree, strategies: [current])
            default:
                fatalError("\(#function) can't be called with \(path)")
            }
        }
        return nil
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
                if let result = shrinks.next() {
//                    print("Sequence continuing strategy for:\n \(result)")
                    // We still have shrinks left in this sequence strategy
                    self.state = .sequence(shrinks: shrinks, original: original, metadata: meta, strategy: strategy)
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
                        shrinks: children,
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
                        subIterator: ShrinkingIterator(shrinks[index]),
                        sequenceMetadata: sequenceMetadata,
                        sequenceStrategy: sequenceStrategy
                    )
                    continue
                }
            case let .choice(shrinks, meta, strategy):
                guard let result = shrinks.next() else {
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
                self.state = .choice(shrinks: shrinks, metadata: meta, strategy: strategy)
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
            case .resize(let newSize, var choices, var index, let subIterators, var exhaustedChildren):
                if let subResult = subIterators[index].next() {
                    choices[index] = subResult
                    // There's still a result, update the choice, and if it's not an important part, move to the next one (round-robin)
                    index = choices[index].isImportant ? index : (index + 1) % choices.count
                    // Skip exhausted children
                    while exhaustedChildren.contains(index) && exhaustedChildren.count < choices.count {
                        index = (index + 1) % choices.count
                    }
                    if exhaustedChildren.count >= choices.count {
                        state = .exhausted
                        return nil
                    }
                    state = .resize(newSize: newSize, choices: choices, childIndex: index, subIterators: subIterators, exhaustedChildren: exhaustedChildren)
                    return ChoiceTree.resize(newSize: newSize, choices: Array(choices))
                } else {
                    // This choice is exhausted, mark it and move to next
                    exhaustedChildren.insert(index)
                    if exhaustedChildren.count >= choices.count {
                        state = .exhausted
                        return nil
                    }
                    index = (index + 1) % choices.count
                    // Skip exhausted children
                    while exhaustedChildren.contains(index) {
                        index = (index + 1) % choices.count
                    }
                    state = .resize(newSize: newSize, choices: choices, childIndex: index, subIterators: subIterators, exhaustedChildren: exhaustedChildren)
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


