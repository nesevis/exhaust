/// Keeps one pending entry per enumeration row so priority merging does not materialize the row's remaining scopes.
///
/// The greatest entry is emitted first. Entries include their discovery order when stable priority ties matter; the queue itself does not invent a tie-breaking policy.
struct ScopePriorityQueue<Entry: Comparable> {
    private var entries: [Entry] = []

    /// Inserts a row's next entry in O(log *n*) time, where *n* is the number of pending rows.
    mutating func insert(_ entry: Entry) {
        entries.append(entry)
        var index = entries.count - 1
        while index > 0 {
            let parent = (index - 1) / 2
            guard entries[index] > entries[parent] else {
                break
            }
            entries.swapAt(index, parent)
            index = parent
        }
    }

    /// Removes the greatest entry in O(log *n*) time without shifting the remaining entries.
    mutating func popFirst() -> Entry? {
        guard entries.isEmpty == false else {
            return nil
        }
        entries.swapAt(0, entries.count - 1)
        let result = entries.removeLast()
        var index = 0
        while index * 2 + 1 < entries.count {
            let leftChild = index * 2 + 1
            let rightChild = leftChild + 1
            let greaterChild = switch rightChild < entries.count && entries[rightChild] > entries[leftChild] {
                case true:
                    rightChild
                case false:
                    leftChild
            }
            guard entries[greaterChild] > entries[index] else {
                break
            }
            entries.swapAt(index, greaterChild)
            index = greaterChild
        }
        return result
    }
}
