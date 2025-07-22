
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
        case shrinkingChoice(shrinks: [UInt64], nextIndex: Int, metadata: ChoiceMetadata)
        
        // Shrinking a signed integer using semantic interleaving
        case shrinkingSignedChoice(originalBits: UInt64, originalMask: UInt64, shrinks: [UInt64], nextIndex: Int, metadata: ChoiceMetadata)
        
        // Shrinking a floating point value  
        case shrinkingFloatingChoice(originalBits: UInt64, originalMask: UInt64, shrinks: [UInt64], nextIndex: Int, metadata: ChoiceMetadata)
        
        // Shrinking a Character choice by shrinking its Unicode scalar value.
        case shrinkingCharacterChoice(originalCharacter: Character, shrinks: [UInt64], nextIndex: Int, metadata: ChoiceMetadata)

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
                case let .choice(choiceValue, metadata):
                    switch choiceValue {
                    case .unsigned(let bits):
                        // For unsigned integers, use direct bit pattern shrinking
                        let shrinks = shrinkNumberAggressively(bits)
                        state = .shrinkingChoice(shrinks: shrinks, nextIndex: 0, metadata: metadata)
                    case .signed(let bits, let mask):
                        // For signed integers, generate semantic shrinks directly
                        let shrinks = shrinkSignedIntegerDirectly(bits: bits, mask: mask)
                        state = .shrinkingSignedChoice(originalBits: bits, originalMask: mask, shrinks: shrinks, nextIndex: 0, metadata: metadata)
                    case .floating(let bits, let mask):
                        // For floating point, use direct bit pattern shrinking for now
                        let shrinks = shrinkNumberAggressively(bits)  
                        state = .shrinkingFloatingChoice(originalBits: bits, originalMask: mask, shrinks: shrinks, nextIndex: 0, metadata: metadata)
                    case .character(_):
                        // Handle characters separately as before
                        let character = choiceValue.convertible as! Character
                        let firstScalar = character.unicodeScalars.first?.value ?? 0
                        let shrinks = shrinkNumberAggressively(UInt64(firstScalar)).sorted()
                        state = .shrinkingCharacterChoice(originalCharacter: character, shrinks: shrinks, nextIndex: 0, metadata: metadata)
                    }
                case .just:
                    state = .finished
                
                case .sequence(_, let elements, let metadata):
                    // The first strategy for a sequence is to shrink its length.
                    let lengthShrinks = shrinkNumber(UInt64(elements.count)).sorted()
                    // Use the first valid range from metadata, or a default range
                    let validRange = metadata.validRanges.first ?? (0...UInt64.max)
                    state = .shrinkingSequenceLength(originalElements: elements, lengthShrinks: lengthShrinks, nextIndex: 0, validRange: validRange, prefix: true)
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

            case let .shrinkingChoice(shrinks, index, metadata):
                if index >= shrinks.count {
                    // We've exhausted all numeric shrinks. We're done.
                    state = .finished
                    return nil
                }
                // Move state to the next index for the next call.
                state = .shrinkingChoice(shrinks: shrinks, nextIndex: index + 1, metadata: metadata)
                // Yield the current shrink.
                return .choice(.init(shrinks[index]), metadata)
            
            case let .shrinkingSignedChoice(originalBits, originalMask, shrinks, index, metadata):
                if index >= shrinks.count {
                    state = .finished
                    return nil
                }
                state = .shrinkingSignedChoice(originalBits: originalBits, originalMask: originalMask, shrinks: shrinks, nextIndex: index + 1, metadata: metadata)
                // shrinks[index] is already the signed bit pattern
                return .choice(.signed(shrinks[index], originalMask), metadata)
            
            case let .shrinkingFloatingChoice(originalBits, originalMask, shrinks, index, metadata):
                if index >= shrinks.count {
                    state = .finished
                    return nil
                }
                state = .shrinkingFloatingChoice(originalBits: originalBits, originalMask: originalMask, shrinks: shrinks, nextIndex: index + 1, metadata: metadata)
                return .choice(.floating(shrinks[index], originalMask), metadata)
            
            case let .shrinkingCharacterChoice(originalCharacter, shrinks, index, metadata):
                if index >= shrinks.count {
                    // We've exhausted all Character shrinks. We're done.
                    state = .finished
                    return nil
                }
                // Move state to the next index for the next call.
                state = .shrinkingCharacterChoice(originalCharacter: originalCharacter, shrinks: shrinks, nextIndex: index + 1, metadata: metadata)
                // Create a new Character from the shrunk scalar value
                let shrunkScalar = shrinks[index]
                if let unicodeScalar = Unicode.Scalar(UInt32(shrunkScalar)) {
                    let shrunkCharacter = Character(unicodeScalar)
                    return .choice(.init(shrunkCharacter), metadata)
                } else {
                    // If invalid scalar, skip this shrink
                    state = .shrinkingCharacterChoice(originalCharacter: originalCharacter, shrinks: shrinks, nextIndex: index + 1, metadata: metadata)
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
                let metadata = ChoiceMetadata(validRanges: [range], strategies: ShrinkingStrategy.sequences)
                return .sequence(length: UInt64(newLength), elements: newElements, metadata)

            case let .shrinkingSequenceElement(originalElements, elementIndex, elementIterator, range):
                // Try to get the next shrink from the CURRENT element's iterator.
                if let shrunkElement = elementIterator.next() {
                    // Success! We got a smaller version of the element.
                    var newElements = originalElements
                    newElements[elementIndex] = shrunkElement
                    
                    // We need to keep our own iterator's state up-to-date for the *next* call.
                    state = .shrinkingSequenceElement(originalElements: originalElements, currentElementIndex: elementIndex, elementIterator: elementIterator, validRange: range)

                    // Yield the whole sequence with just one element shrunk.
                    let metadata = ChoiceMetadata(validRanges: [range], strategies: ShrinkingStrategy.sequences)
                    return .sequence(length: UInt64(newElements.count), elements: newElements, metadata)
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
    
    private func shrinkSignedIntegerDirectly(bits: UInt64, mask: UInt64) -> [UInt64] {
        // Convert normalized bits back to actual signed integer value
        let bitWidth = 64 - mask.leadingZeroBitCount
        let signBit = UInt64(1) << (bitWidth - 1)
        
        let actualSignedValue: Int64
        if bits >= signBit {
            // Originally positive
            actualSignedValue = Int64(bits - signBit)
        } else {
            // Originally negative  
            actualSignedValue = -Int64(signBit - bits)
        }
        
        // Generate candidate signed integers in semantic order: 1, 0, -1, 2, -2, 3, -3, ...
        var candidates: [Int64] = []
        
        let absValue = abs(actualSignedValue)
        
        // For small numbers, enumerate systematically with 1 prioritized before 0
        if absValue <= 100 && absValue > 0 {
            // Special case: if we're already at 1, don't try to shrink to 0 
            // (1 is often the desired boundary value)
            if absValue == 1 {
                // Don't generate any candidates for 1 - it's minimal enough
                return []
            }
            
            // Add 1 first (most common boundary case)
            candidates.append(1)
            
            if absValue >= 2 {
                for i in 2...absValue {
                    candidates.append(Int64(i))      // 2, 3, 4, ...
                    candidates.append(0)             // 0 after each positive (except 1)
                    candidates.append(-Int64(i-1))   // -1, -2, -3, ...
                }
            }
            
            // Add 0 and -1 at the end for thoroughness
            candidates.append(0)
            candidates.append(-1)
        } else {
            // For larger numbers, use aggressive shrinking approach
            let steps: [Int64] = [1, 2, 3, 5, 10, 25, 50, 100]
            for step in steps {
                if abs(actualSignedValue) > step {
                    candidates.append(actualSignedValue > 0 ? actualSignedValue - step : actualSignedValue + step)
                }
            }
            
            // Add the key boundary values
            candidates.append(1)
            candidates.append(0)
            candidates.append(-1)
        }
        
        // Remove duplicates and values that are >= original in magnitude
        let uniqueCandidates = Array(Set(candidates))
            .filter { abs($0) < abs(actualSignedValue) }
            .sorted { first, second in
                // Prioritize 1 over 0 for boundary testing (1 is often more meaningful)
                if first == 1 && second == 0 { return true }
                if first == 0 && second == 1 { return false }
                
                // For other values, sort by absolute value (complexity), then positive over negative
                let firstAbs = abs(first)
                let secondAbs = abs(second)
                if firstAbs != secondAbs {
                    return firstAbs < secondAbs
                }
                // Same absolute value - prefer positive
                return first > second
            }
        
        // Convert back to normalized bit patterns
        let result = uniqueCandidates.compactMap { candidate in
            if candidate >= 0 {
                return UInt64(candidate) + signBit
            } else {
                return signBit - UInt64(-candidate)
            }
        }
        
        // Debug output
        print("Shrinking \(actualSignedValue) -> candidates: \(uniqueCandidates)")
        return result
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
