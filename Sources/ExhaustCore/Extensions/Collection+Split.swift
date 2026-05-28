//
//  Collection+Split.swift
//  Exhaust
//

package extension Collection {
    /// Splits the collection into two halves. The second half gets the extra element when the count is odd.
    func halved() -> (first: [Element], second: [Element]) {
        let mid = count / 2
        return (Array(prefix(mid)), Array(dropFirst(mid)))
    }
}
