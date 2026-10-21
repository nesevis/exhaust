import Foundation

// MARK: - Breadcrumb Layout

/// The candidate hash of the breadcrumb's committed slot, or nil when neither slot carries the commit marker.
///
/// The file is two fixed-size slots (48 header bytes plus a 4096-byte payload each); a slot's first word is the commit marker once the rest is written, and the candidate hash sits at offset 16. Mirrors `FuzzBreadcrumb`'s layout, which this package cannot read directly.
public func committedCandidateHash(in breadcrumb: Data) -> UInt64? {
    let slotSize = 48 + 4096
    let commitMarker: UInt64 = 0x4558_4855_5354_4332
    func word(at offset: Int) -> UInt64 {
        breadcrumb[offset ..< offset + 8].reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }
    guard breadcrumb.count == slotSize * 2 else {
        return nil
    }
    for slot in 0 ..< 2 where word(at: slot * slotSize) == commitMarker {
        return word(at: slot * slotSize + 16)
    }
    return nil
}
