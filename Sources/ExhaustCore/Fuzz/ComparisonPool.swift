// Site-keyed dictionary of comparison operands harvested from the system under test.

/// Groups the operands the trace-cmp hooks harvest by comparison site, for the mutator to draw on during injection.
///
/// Keying by call site is what makes a cascade solvable. A shallow comparison fires on every attempt, so in a flat pool its constant floods every draw and the constants of deeper comparisons — which only fire once the earlier ones match — are never picked. With one small recency ring per site, each site's own recurring constant is a large share of that site's ring, and a draw that first picks a site uniformly gives every comparison, shallow or deep, an equal chance to contribute. Both operands of a comparison enter under its site key; which one is the wanted constant is not knowable, so the draw tries either.
package struct ComparisonPool: Sendable {
    private struct Site: Sendable {
        var values: [UInt64] = []
        var cursor = 0

        mutating func insert(_ value: UInt64, cap: Int) {
            if values.count < cap {
                values.append(value)
            } else {
                values[cursor] = value
                cursor += 1
                if cursor == cap {
                    cursor = 0
                }
            }
        }
    }

    /// Maps a comparison site to the index of its ring in ``rings``. The indirection makes site selection a direct array index rather than a second dictionary lookup, and removes the parallel key list the previous layout had to keep in sync with the dictionary by hand.
    private var sites: [UInt64: Int] = [:]
    private var rings: [Site] = []

    /// Recent operands retained per comparison site. Small, so a site's recurring constant dominates its own ring and stale operands age out quickly.
    private let perSiteCapacity: Int

    package init(perSiteCapacity: Int = 64) {
        self.perSiteCapacity = perSiteCapacity
    }

    /// Records one harvested operand under its comparison site.
    package mutating func insert(site: UInt64, value: UInt64) {
        if let index = sites[site] {
            rings[index].insert(value, cap: perSiteCapacity)
        } else {
            sites[site] = rings.count
            var ring = Site()
            ring.insert(value, cap: perSiteCapacity)
            rings.append(ring)
        }
    }

    /// Whether the pool holds nothing to inject.
    package var isEmpty: Bool {
        rings.isEmpty
    }

    /// Draws one operand: picks a comparison site uniformly, then a value from that site's ring.
    ///
    /// Uniform over sites rather than over all operands, so a site that fires rarely (a deep comparison reached only after earlier ones match) is drawn as often as one that fires constantly — the property that lets the frontier constant surface.
    ///
    /// - Parameters:
    ///   - sitePick: A uniform draw in [0, 1) selecting the site.
    ///   - valuePick: A uniform draw in [0, 1) selecting the value within the site.
    package func drawValue(sitePick: Double, valuePick: Double) -> UInt64? {
        guard rings.isEmpty == false else {
            return nil
        }
        let values = rings[Swift.min(Int(sitePick * Double(rings.count)), rings.count - 1)].values
        guard values.isEmpty == false else {
            return nil
        }
        return values[Swift.min(Int(valuePick * Double(values.count)), values.count - 1)]
    }
}
