
final class ShrinkCandidateIterator: IteratorProtocol {
    typealias Element = ChoiceTree

    private let originalTree: ChoiceTree
    private var state: State

    // The state machine that tracks our progress.
    private enum State {
        // Initial state, before any shrinks are produced.
        case initial

        // Shrinking a primitive UInt64 value.
        // We store all potential shrinks and an index to the next one to yield.
        case shrinkingChoice(shrinks: [UInt64], nextIndex: Int)
        
        // Shrinking a Character choice by shrinking its Unicode scalar value.
        case shrinkingCharacterChoice(originalCharacter: Character, shrinks: [UInt64], nextIndex: Int)

        // Shrinking a sequence. This is a multi-stage process.
        // Stage 1: Shrink the sequence's length.
        case shrinkingSequenceLength(originalElements: [ChoiceTree], lengthShrinks: [UInt64], nextIndex: Int, validRange: ClosedRange<UInt64>, prefix: Bool)
        // Stage 2: Shrink the elements within the sequence, one by one.
        // This is recursive: the elementIterator is another ShrinkCandidateIterator!
        case shrinkingSequenceElement(originalElements: [ChoiceTree], currentElementIndex: Int, elementIterator: ShrinkCandidateIterator, validRange: ClosedRange<UInt64>)
        
        // NEW: State for shrinking a group of children.
        case shrinkingGroup(
            originalChildren: [ChoiceTree],
            currentChildIndex: Int,
            childIterator: ShrinkCandidateIterator
        )

        // NEW: State for shrinking a branch. It's like a group but needs the label.
        case shrinkingBranch(
            label: UInt64,
            originalChildren: [ChoiceTree],
            currentChildIndex: Int,
            childIterator: ShrinkCandidateIterator
        )
        
        // TODO: Add states for .group and .branch, following the same pattern.
        
        // Final state when no more shrinks can be produced.
        case finished
    }

    init(tree: ChoiceTree) {
        self.originalTree = tree
        self.state = .initial
    }

    func next() -> ChoiceTree? {
        // This is the main logic loop. We use a switch to handle the current state.
        // A 'repeat-while' loop allows us to transition between states (e.g., from
        // shrinking length to shrinking elements) without returning.
        repeat {
            switch state {
            case .initial:
                // When we start, determine what kind of tree we have and move to the first logical state.
                switch originalTree {
                case let .choice(.uint(bits)):
                    // Generate the simple -> complex list of numeric shrinks ONCE.
                    let shrinks = shrinkNumberAggressively(bits) // Sort ascending!
                    state = .shrinkingChoice(shrinks: shrinks, nextIndex: 0)
                case let .choice(.character(character)):
                    // Shrink Character by shrinking its first Unicode scalar value
                    let firstScalar = character.unicodeScalars.first?.value ?? 0
                    let shrinks = shrinkNumberAggressively(UInt64(firstScalar)).sorted()
                    state = .shrinkingCharacterChoice(originalCharacter: character, shrinks: shrinks, nextIndex: 0)
                case .just:
                    state = .finished
                
                case .sequence(_, let elements, let range):
                    // The first strategy for a sequence is to shrink its length.
                    let lengthShrinks = shrinkNumber(UInt64(elements.count)).sorted()
                    state = .shrinkingSequenceLength(originalElements: elements, lengthShrinks: lengthShrinks, nextIndex: 0, validRange: range, prefix: true)
                case let .group(children):
                    if children.isEmpty {
                        state = .finished // Nothing to shrink
                    } else {
                        // Start by trying to shrink the first child (index 0).
                        let firstChildIterator = ShrinkCandidateIterator(tree: children[0])
                        state = .shrinkingGroup(
                            originalChildren: children,
                            currentChildIndex: 0,
                            childIterator: firstChildIterator
                        )
                    }

                // NEW: Handle .branch
                case let .branch(label, children):
                    if children.isEmpty {
                        state = .finished
                    } else {
                        // Start by trying to shrink the first child (index 0).
                        let firstChildIterator = ShrinkCandidateIterator(tree: children[0])
                        state = .shrinkingBranch(
                            label: label,
                            originalChildren: children,
                            currentChildIndex: 0,
                            childIterator: firstChildIterator
                        )
                    }
                }

            case let .shrinkingChoice(shrinks, index):
                if index >= shrinks.count {
                    // We've exhausted all numeric shrinks. We're done.
                    state = .finished
                    return nil
                }
                // Move state to the next index for the next call.
                state = .shrinkingChoice(shrinks: shrinks, nextIndex: index + 1)
                // Yield the current shrink.
                return .choice(.init(shrinks[index]))
            
            case let .shrinkingCharacterChoice(originalCharacter, shrinks, index):
                if index >= shrinks.count {
                    // We've exhausted all Character shrinks. We're done.
                    state = .finished
                    return nil
                }
                // Move state to the next index for the next call.
                state = .shrinkingCharacterChoice(originalCharacter: originalCharacter, shrinks: shrinks, nextIndex: index + 1)
                // Create a new Character from the shrunk scalar value
                let shrunkScalar = shrinks[index]
                if let unicodeScalar = Unicode.Scalar(UInt32(shrunkScalar)) {
                    let shrunkCharacter = Character(unicodeScalar)
                    return .choice(.init(shrunkCharacter))
                } else {
                    // If invalid scalar, skip this shrink
                    state = .shrinkingCharacterChoice(originalCharacter: originalCharacter, shrinks: shrinks, nextIndex: index + 1)
                    return next() // Recursively try the next one
                }

            case let .shrinkingSequenceLength(elements, shrinks, index, range, usePrefix):
                if index >= shrinks.count {
                    // Finished shrinking length. NOW we start shrinking individual elements.
                    // Transition to the next state, starting with the first element (index 0).
                    if !elements.isEmpty {
                        let firstElementIterator = ShrinkCandidateIterator(tree: elements[0])
                        state = .shrinkingSequenceElement(originalElements: elements, currentElementIndex: 0, elementIterator: firstElementIterator, validRange: range)
                    } else {
                        state = .finished
                    }
                    continue // Re-enter the loop to process the new state immediately.
                }

                // Get the next shrunk length
                let newLength = Int(shrinks[index])
                state = .shrinkingSequenceLength(originalElements: elements, lengthShrinks: shrinks, nextIndex: index + 1, validRange: range, prefix: !usePrefix)
                
                // Yield a new sequence with the shorter length (taking the prefix).
                let newElements = Array(usePrefix ? elements.prefix(newLength) : elements.suffix(newLength))
                return .sequence(length: UInt64(newLength), elements: newElements, validRange: range)

            case let .shrinkingSequenceElement(originalElements, elementIndex, elementIterator, range):
                // Try to get the next shrink from the CURRENT element's iterator.
                if let shrunkElement = elementIterator.next() {
                    // Success! We got a smaller version of the element.
                    var newElements = originalElements
                    newElements[elementIndex] = shrunkElement
                    
                    // We need to keep our own iterator's state up-to-date for the *next* call.
                    state = .shrinkingSequenceElement(originalElements: originalElements, currentElementIndex: elementIndex, elementIterator: elementIterator, validRange: range)

                    // Yield the whole sequence with just one element shrunk.
                    return .sequence(length: UInt64(newElements.count), elements: newElements, validRange: range)
                } else {
                    // The iterator for the current element is exhausted. Move to the next one.
                    let nextElementIndex = elementIndex + 1
                    if nextElementIndex >= originalElements.count {
                        // No more elements to shrink. We're totally done.
                        state = .finished
                        return nil
                    }
                    
                    // Create a new iterator for the NEXT element and update state.
                    let nextIterator = ShrinkCandidateIterator(tree: originalElements[nextElementIndex])
                    state = .shrinkingSequenceElement(originalElements: originalElements, currentElementIndex: nextElementIndex, elementIterator: nextIterator, validRange: range)
                    continue // Re-enter loop to process the new state.
                }
            case let .shrinkingGroup(originalChildren, childIndex, childIterator):
            // Try to get the next shrink from the CURRENT child's iterator.
            if let shrunkChild = childIterator.next() {
                // We got a smaller version of the child.
                var newChildren = originalChildren
                newChildren[childIndex] = shrunkChild
                
                // Update our state before returning. We are still iterating on the same child.
                state = .shrinkingGroup(originalChildren: originalChildren, currentChildIndex: childIndex, childIterator: childIterator)
                
                // Yield the whole group with the one shrunk child.
                return .group(newChildren)
                
            } else {
                // That child's iterator is exhausted. Move to the next child.
                let nextChildIndex = childIndex + 1
                if nextChildIndex >= originalChildren.count {
                    // No more children to shrink. We're done with this group.
                    state = .finished
                    return nil
                }
                
                // Create a new iterator for the NEXT child and update state.
                let nextChildIterator = ShrinkCandidateIterator(tree: originalChildren[nextChildIndex])
                state = .shrinkingGroup(
                    originalChildren: originalChildren,
                    currentChildIndex: nextChildIndex,
                    childIterator: nextChildIterator
                )
                continue // Loop again to start processing the new state.
            }

        // NEW: Logic for shrinking a branch
        case let .shrinkingBranch(label, originalChildren, childIndex, childIterator):
            // This logic is identical to .shrinkingGroup, just with a different return type.
            if let shrunkChild = childIterator.next() {
                var newChildren = originalChildren
                newChildren[childIndex] = shrunkChild
                
                state = .shrinkingBranch(label: label, originalChildren: originalChildren, currentChildIndex: childIndex, childIterator: childIterator)
                
                // The only difference: we reconstruct a .branch, preserving the label.
                return .branch(label: label, children: newChildren)
                
            } else {
                let nextChildIndex = childIndex + 1
                if nextChildIndex >= originalChildren.count {
                    state = .finished
                    return nil
                }
                
                let nextChildIterator = ShrinkCandidateIterator(tree: originalChildren[nextChildIndex])
                state = .shrinkingBranch(
                    label: label,
                    originalChildren: originalChildren,
                    currentChildIndex: nextChildIndex,
                    childIterator: nextChildIterator
                )
                continue
            }
            
            case .finished:
                return nil
            }
        } while true // The loop is exited by returning a value or nil.
    }
    
    private func shrinkNumberAggressively(_ n: UInt64) -> [UInt64] {
        return shrinkNumberAggressively(n, validRange: UInt64.min...UInt64.max)
    }
    
    private func shrinkNumberAggressively(_ number: UInt64, validRange: ClosedRange<UInt64>) -> [UInt64] {
        var shrinks: Set<UInt64> = []
        
        // Use the valid range's lower bound instead of 0
        let effectiveMin = validRange.lowerBound
        
        // For Character values, try meaningful character values first
//        if (48...255).contains(number) {
//            // Common minimal characters in ascending order of preference
//            let commonChars: [UInt64] = [65, 97, 48, 32] // 'A', 'a', '0', ' '
//            for char in commonChars {
//                if char < number && validRange.contains(char) {
//                    shrinks.insert(char)
//                }
//            }
//        }
        
        // For small numbers, try every integer down to effective minimum
        if number <= 10 {
            for i in (validRange.lowerBound..<number).reversed() {
                shrinks.insert(i)
            }
        } else {
            // For larger numbers, use more aggressive steps but respect valid range
            let steps: [UInt64] = [1, 2, 3, 5, 10, 25, 50, 100]
            for step in steps {
                if step <= number { // Prevent underflow
                    let candidate = number - step
                    if candidate >= effectiveMin && validRange.upperBound >= candidate {
                        shrinks.insert(candidate)
                    }
                }
            }
            
            // Then use binary search approach
            var x = number / 2
            while x > 100 {
                if x <= number { // Prevent underflow
                    let candidate = number - x
                    if candidate >= effectiveMin && validRange.upperBound >= candidate {
                        shrinks.insert(candidate)
                    }
                }
                x /= 2
            }
        }
        let result = shrinks.sorted(by: <)
        return result
    }
    
    private func shrinkNumber(_ n: UInt64) -> [UInt64] {
        var shrinks: [UInt64] = []
        if n != 0 {
            shrinks.append(0)
        }
        
        var x = n / 2
        while x > 0 {
            shrinks.append(n - x)
            x /= 2
        }
        return shrinks
    }
}

struct ShrinkCandidateSequence: Sequence {
    let tree: ChoiceTree

    init(tree: ChoiceTree) {
        self.tree = tree
    }

    /// Conformance to the Sequence protocol.
    /// - Returns: A new, independent iterator for this sequence.
    func makeIterator() -> ShrinkCandidateIterator {
        return ShrinkCandidateIterator(tree: tree)
    }
}
