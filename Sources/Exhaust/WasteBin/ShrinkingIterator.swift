////
////  HierarchicalTieredShrinker.swift
////  Exhaust
////
////  Created by Chris Kolbu on 21/7/2025.
////
//
//final class ShrinkingIterator: IteratorProtocol {
//    typealias Element = ChoiceTree
//    typealias Strategy = any AnyStrategyIterator
//    typealias EagerShrinks = [ChoiceTree]
//    private typealias Shrink = (ChoiceTree?, State)
//    
//    /// The original candidate
//    private var origin: ChoiceTree
//    private var isImportant: Bool
//    private var isSelected: Bool
//    
//    /// The internal state of the iterator
//    private var state: State
//    
//    init(_ candidate: ChoiceTree) {
////        print("New shrinker iterator!" \(candidate.elementDescription)\n\(candidate.effectiveRange?.description ?? "No range")")
//        self.origin = candidate
//        self.isImportant = candidate.isImportant
//        self.isSelected = candidate.isSelected
//        self.state = .idle
//        print("New shrinker iterator: [I:\(isImportant)|S:\(isSelected)] \(candidate)")
//    }
//    
//    private enum State {
//        case idle
//        case exhausted
//        
//        /// Representing a ChoiceTree.choice
//        case choice(shrinks: Strategy, metadata: ChoiceMetadata, strategy: [any TemporaryDualPurposeStrategy])
//
//        /// Representing a ChoiceTree.sequence
//        case sequence(shrinks: Strategy, original: Strategy, metadata: ChoiceMetadata, strategy: [any TemporaryDualPurposeStrategy])
//        
//        /// Representing the element of a ChoiceTree.sequence. `shrinks` is presented as a subsequence, but is never sliced beyond its original size
//        case element(shrinks: EagerShrinks, childIndex: Int, subIterator: ShrinkingIterator, sequenceMetadata: ChoiceMetadata, sequenceStrategy: [any TemporaryDualPurposeStrategy])
//        
//        /// Representing a group that is being shrunk
//        case group(children: EagerShrinks, childIndex: Int, subIterators: [ShrinkingIterator?], exhaustedChildren: Set<Int>)
//        
//        /// Representing a branch in the ``ChoiceTree``
//        case branch(label: UInt64, weight: UInt64, children: EagerShrinks, childIndex: Int, subIterators: [ShrinkingIterator], exhaustedChildren: Set<Int>)
//        
//        /// Representing a resize node with nested choices
//        case resize(newSize: UInt64, choices: EagerShrinks, childIndex: Int, subIterators: [ShrinkingIterator], exhaustedChildren: Set<Int>)
//    }
//    
//    /// This kicks off the initial round of shrinks. It will go by strategy
//    private func handle(first: ChoiceTree) -> Shrink {
//        switch first {
//        case let .choice(_, meta):
//            // If the first strategy is a no go, this returns early
//            // We should be rotating, but we can't easily do that here. It may have to be
//            guard let shrinks = self.strategyValues(for: first, strategies: meta.strategies), let first = shrinks.next() else {
//                return (nil, .exhausted)
//            }
//            return (first, .choice(shrinks: shrinks, metadata: meta, strategy: first.strategy))
//        case .just:
//            return (nil, .exhausted)
//        case let .sequence(_, _, meta):
//            guard let shrinks = self.strategyValues(for: first, strategies: meta.strategies), let first = shrinks.next() else {
//                return (nil, .exhausted)
//            }
//            // FIXME: Don't materialise the sequence here
//            return (first, .sequence(shrinks: shrinks, original: shrinks, metadata: meta, strategy: first.strategy))
//        case let .branch(weight, label, gen):
//            let subIterators = [ShrinkingIterator(gen)]
//            return (first, .branch(label: label, weight: weight, children: [gen], childIndex: 0, subIterators: subIterators, exhaustedChildren: []))
//        case let .group(array):
//            // If a group contains branches, we should look for the selected one and only shrink that. This means there is no round robin.
//            guard array.isEmpty == false else {
//                return (nil, .exhausted)
//            }
//            let hasPickWithSelection = array.contains(where: \.isSelected)
//            let subIterators = array.map {
//                // If this is a sum type `pick` where only one branch is active, only create a generator for that value
//                if hasPickWithSelection {
//                    return $0.isSelected ? ShrinkingIterator($0) : nil
//                }
//                // If not, and this is a product type, return generators for all values
//                return ShrinkingIterator($0)
//            }
//            // We should be returning a group here.
//            return (first, .group(children: array, childIndex: array.firstIndex(where: { $0.isSelected || $0.isImportant }) ?? 0, subIterators: subIterators, exhaustedChildren: []))
//        case let .important(value):
//            return handle(first: value)
//        case let .selected(value):
//            return handle(first: value)
//        case .getSize:
//            // getSize nodes can't be shrunk, they represent constant size values
//            return (nil, .exhausted)
//        case let .resize(newSize, choices):
//            // For resize nodes, shrink the nested choices
//            guard !choices.isEmpty else {
//                return (nil, .exhausted)
//            }
//            let subIterators = choices.map { ShrinkingIterator($0) }
//            return (first, .resize(newSize: newSize, choices: choices, childIndex: 0, subIterators: subIterators, exhaustedChildren: []))
//        }
//    }
//    
//    // MARK: - IteratorProtocol
//    
//    func next() -> ChoiceTree? {
//        // Sequences will sometimes defer their work to the next cycle, so this is wrapped in a while
//        while true {
//            switch state {
//            case .idle:
//                let (result, state) = self.handle(first: origin)
//                self.state = state
//                if case .group = result {
//                    continue
//                }
//                if let result {
//                    if isImportant, result.isImportant == false {
//                        return .important(result)
//                    }
//                    if isSelected, result.isSelected == false {
//                        return .selected(result)
//                    }
//                    if result.isJust {
//                        // What?
////                        return nil
//                    }
//                    return result
//                }
//                continue
//            case .exhausted:
//                return nil
//            case let .sequence(shrinks, original, meta, strategy):
//                if let result = shrinks.next() {
////                    print("Sequence continuing strategy for:\n \(result)")
//                    // We still have shrinks left in this sequence strategy
//                    self.state = .sequence(shrinks: shrinks, original: original, metadata: meta, strategy: strategy)
//                    if isImportant, result.isImportant == false {
//                        return .important(result)
//                    }
//                    if isSelected, result.isSelected == false {
//                        return .selected(result)
//                    }
//                    return result
//                }
//                if origin.isImportant {
//                    state = .exhausted
//                    return nil
//                }
//                // Try the next strategies with the original input
//                let new = origin.with(strategies: strategy)
//                let (result, state) = self.handle(first: new)
//                if let result {
//                    // We still have other sequence strategies to try
////                    print("Sequence switching strategy for:\n \(result)")
//                    self.state = state
//                    if isImportant, result.isImportant == false {
//                        return .important(result)
//                    }
//                    if isSelected, result.isSelected == false {
//                        return .selected(result)
//                    }
//                    return result
//                }
//                // Strategies are exhausted; move on to the children
//                // These are all the elements. We keep all the strategies from `origin` intact
//                let children = new.children
//                if let first = children.first {
//                    self.state = .element(
//                        shrinks: children,
//                        childIndex: 0,
//                        subIterator: .init(first),
//                        // This is interesting. These should belong to the child?
//                        sequenceMetadata: origin.metadata,
//                        sequenceStrategy: origin.strategy
//                    )
//                    continue
//                }
//                // Children are exhausted; go home
//                self.state = .exhausted
//                return nil
//                
//            case .element(var shrinks, var index, let subIterator, let sequenceMetadata, let sequenceStrategy):
//                // Try to get a shrink for this element
//                if let subResult = subIterator.next() {
//                    // Success! We got a smaller version of the element.
////                    print("Element continuing strategy for index \(index):\n \(subResult)")
//                    shrinks[index] = subResult
//                    state = .element(
//                        shrinks: shrinks,
//                        childIndex: index,
//                        subIterator: subIterator,
//                        sequenceMetadata: sequenceMetadata,
//                        sequenceStrategy: sequenceStrategy
//                    )
//                    // We return a sequence here, so it's important that the metadata is that of the sequence
//                    return .sequence(
//                        length: UInt64(shrinks.count),
//                        elements: shrinks,
//                        sequenceMetadata
//                    )
//                } else {
//                    // The iterator for the current element is exhausted. Move to the next one.
//                    index += 1
//                    if (index >= shrinks.count) {
//                        // We're done
////                        print("Element shrink completed")
//                        state = .exhausted
//                        return nil
//                    }
//                    // Shrink the next element
//                    state = .element(
//                        shrinks: shrinks,
//                        childIndex: index,
//                        subIterator: ShrinkingIterator(shrinks[index]),
//                        sequenceMetadata: sequenceMetadata,
//                        sequenceStrategy: sequenceStrategy
//                    )
//                    continue
//                }
//            case let .choice(shrinks, meta, strategy):
//                guard let result = shrinks.next() else {
//                    // Go to the next strategy, if available
//                    let (result, state) = self.handle(first: origin.with(strategies: strategy))
//                    if let result {
////                        print("Choice switching strategy for:\n \(result)")
//                        self.state = state
//                        if isImportant, result.isImportant == false {
//                            return .important(result)
//                        }
//                        if isSelected, result.isSelected == false {
//                            return .selected(result)
//                        }
//                        return result
//                    }
////                    print("Choice exhausted")
//                    self.state = .exhausted
//                    return nil
//                }
////                print("Choice continuing strategy for:\n \(result)")
//                self.state = .choice(shrinks: shrinks, metadata: meta, strategy: strategy)
//                return result
//            case .group(var children, var index, let subIterators, var exhaustedChildren):
//                // If the strategy is trying to return a value that is outside the range of the choice,
//                // we return nil and exhaust the subiterator
//                // If this group represents a `pick` with an array of `branch`, the subIterators array has optional generators and only the selected branch will have one
//                if let subResult = subIterators[index]?.next() {
//                    let isSelected = children[index].isSelected
//                    children[index] = isSelected && subResult.isSelected == false
//                        ? .selected(subResult)
//                        : subResult
//                    // There's still a result, update the child, and if it's not an important part, or a selected branch (in which case this group represents a pick, move to the next one (round-robin)
//                    index = children[index].isSelected || children[index].isImportant
//                        ? index
//                        : (index + 1) % children.count
//                    // Skip exhausted children
//                    while exhaustedChildren.contains(index) && exhaustedChildren.count < children.count {
//                        index = (index + 1) % children.count
//                    }
//                    if exhaustedChildren.count >= children.count {
//                        state = .exhausted
//                        return nil
//                    }
//                    if isSelected { /*subResult.rangeIsExhausted {*/
//                        state = .exhausted
//                        return nil
//                    }
//                    state = .group(children: children, childIndex: index, subIterators: subIterators, exhaustedChildren: exhaustedChildren)
//                    return ChoiceTree.group(children)
//                } else {
//                    // This child is exhausted, mark it and move to next
//                    exhaustedChildren.insert(index)
//                    if exhaustedChildren.count >= children.count {
//                        state = .exhausted
//                        return nil
//                    }
//                    index = (index + 1) % children.count
//                    // Skip exhausted children
//                    while exhaustedChildren.contains(index) {
//                        index = (index + 1) % children.count
//                    }
//                    state = .group(children: children, childIndex: index, subIterators: subIterators, exhaustedChildren: exhaustedChildren)
//                    continue
//                }
//            case .branch(let label, let weight, var children, var index, let subIterators, var exhaustedChildren):
//                // FIXME: There needs to be a way to "throw away" the branches here that are duds, without removing them from the recipe. A new `.ignored` case?
//                if let subResult = subIterators[index].next() {
//                    children[index] = subResult
//                    // There's still a result, update the child, and if it's not an important part, move to the next one (round-robin)
//                    index = children[index].isImportant ? index : (index + 1) % children.count
//                    // Skip exhausted children
//                    while exhaustedChildren.contains(index) && exhaustedChildren.count < children.count {
//                        index = (index + 1) % children.count
//                    }
//                    if exhaustedChildren.count >= children.count {
//                        state = .exhausted
//                        return nil
//                    }
//                    state = .branch(label: label, weight: weight, children: children, childIndex: index, subIterators: subIterators, exhaustedChildren: exhaustedChildren)
//                    return ChoiceTree.branch(weight: weight, label: label, choice: children[0])
//                } else {
//                    // This child is exhausted, mark it and move to next
//                    exhaustedChildren.insert(index)
//                    if exhaustedChildren.count >= children.count {
//                        state = .exhausted
//                        return nil
//                    }
//                    index = (index + 1) % children.count
//                    // Skip exhausted children
//                    while exhaustedChildren.contains(index) {
//                        index = (index + 1) % children.count
//                    }
//                    state = .branch(label: label, weight: weight, children: children, childIndex: index, subIterators: subIterators, exhaustedChildren: exhaustedChildren)
//                    continue
//                }
//            case .resize(let newSize, var choices, var index, let subIterators, var exhaustedChildren):
//                if let subResult = subIterators[index].next() {
//                    choices[index] = subResult
//                    // There's still a result, update the choice, and if it's not an important part, move to the next one (round-robin)
//                    index = choices[index].isImportant ? index : (index + 1) % choices.count
//                    // Skip exhausted children
//                    while exhaustedChildren.contains(index) && exhaustedChildren.count < choices.count {
//                        index = (index + 1) % choices.count
//                    }
//                    if exhaustedChildren.count >= choices.count {
//                        state = .exhausted
//                        return nil
//                    }
//                    state = .resize(newSize: newSize, choices: choices, childIndex: index, subIterators: subIterators, exhaustedChildren: exhaustedChildren)
//                    return ChoiceTree.resize(newSize: newSize, choices: choices)
//                } else {
//                    // This choice is exhausted, mark it and move to next
//                    exhaustedChildren.insert(index)
//                    if exhaustedChildren.count >= choices.count {
//                        state = .exhausted
//                        return nil
//                    }
//                    index = (index + 1) % choices.count
//                    // Skip exhausted children
//                    while exhaustedChildren.contains(index) {
//                        index = (index + 1) % choices.count
//                    }
//                    state = .resize(newSize: newSize, choices: choices, childIndex: index, subIterators: subIterators, exhaustedChildren: exhaustedChildren)
//                    continue
//                }
//            }
//        }
//    }
//    
//    // MARK: - Strategies
//    
//    private func strategyValues(for path: ChoiceTree, strategies: [any TemporaryDualPurposeStrategy]) -> Strategy? {
//        var remaining = strategies
//        while remaining.isEmpty == false {
//            let current = remaining.removeFirst()
//            switch path {
//            case .choice(let choiceValue, let metadata):
//                let rawRange = metadata.validRanges[0]
//                switch choiceValue {
//                case .unsigned(let uint):
//                    return StrategyIterator(initial: uint, strategy: current, inRange: [rawRange], current.next(for:)) { next in
//                        ChoiceTree.choice(ChoiceValue(next, tag: .uint64), metadata).with(strategies: remaining)
//                    }
//                case .signed(let int, _, _):
//                    let castRange = Int64(bitPattern64: rawRange.lowerBound)...Int64(bitPattern64: rawRange.upperBound)
//                    return StrategyIterator(initial: int, strategy: current, inRange: [castRange], current.next(for:)) { next in
//                        ChoiceTree.choice(ChoiceValue(next, tag: .int64), metadata).with(strategies: remaining)
//                    }
//                case .floating(let double, _, _):
//                    let castRange = Double(bitPattern64: rawRange.lowerBound)...Double(bitPattern64: rawRange.upperBound)
//                    return StrategyIterator(initial: double, strategy: current, inRange: [castRange], current.next(for:)) { next in
//                        ChoiceTree.choice(ChoiceValue(next, tag: .double), metadata).with(strategies: remaining)
//                    }
//                case .character(let character):
//                    let castRanges = metadata.validRanges.map { range in
//                        Character(bitPattern64: range.lowerBound)...Character(bitPattern64: range.upperBound)
//                    }
//                    return StrategyIterator(initial: character, strategy: current, inRange: castRanges, current.next(for:)) { next in
//                        ChoiceTree.choice(ChoiceValue(next, tag: .character), metadata).with(strategies: remaining)
//                    }
//                }
//            case .sequence(_, let elements, let metadata):
//                let rawRange = metadata.validRanges[0]
//                let castRange = Int(rawRange.lowerBound)...(rawRange.upperBound == .max ? Int.max : Int(rawRange.upperBound))
//                
//                guard elements.isEmpty == false else {
//                    return nil
//                }
//                
//                return StrategySequenceIterator(initial: elements, strategy: current, inRange: castRange, current.next(for:)) { values in
//                    ChoiceTree.sequence(length: UInt64(values.count), elements: Array(values), metadata).with(strategies: remaining)
//                }
//            case .important(let choiceTree):
//                // FIXME: This feels suboptimal
//                return self.strategyValues(for: choiceTree, strategies: [current])
//            default:
//                fatalError("\(#function) can't be called with \(path)")
//            }
//        }
//        return nil
//    }
//}
//
//extension ChoiceTree {
//    var metadata: ChoiceMetadata {
//        switch self {
//        case let .choice(_, meta), let .sequence(_, _, meta):
//            return meta
//        case let .group(array):
//            if let meta = array.first(where: { $0.metadata.validRanges.isEmpty == false })?.metadata {
//                return meta
//            }
//            fallthrough
//        default:
//            return ChoiceMetadata(validRanges: [], strategies: [])
//        }
//    }
//    
//    var strategy: [any TemporaryDualPurposeStrategy] {
//        self.metadata.strategies
//    }
//    
//    func with(strategies: [any TemporaryDualPurposeStrategy]) -> ChoiceTree {
//        switch self {
//        case let .choice(value, meta):
//            let newMeta = ChoiceMetadata(validRanges: meta.validRanges, strategies: strategies)
//            return .choice(value, newMeta)
//        case let .sequence(length, elements, meta):
//            let newMeta = ChoiceMetadata(validRanges: meta.validRanges, strategies: strategies)
//            return .sequence(length: length, elements: elements, newMeta)
//        case let .important(value):
//            return .important(value.with(strategies: strategies))
//        case let .selected(value):
//            return .selected(value.with(strategies: strategies))
//        default:
//            fatalError("\(#function) should not be accessed directly by \(self)")
//        }
//    }
//}
//
//
