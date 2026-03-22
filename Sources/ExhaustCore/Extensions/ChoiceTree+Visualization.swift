//
//  ChoiceTree+Visualization.swift
//  Exhaust
//

// MARK: - Public API

public extension ChoiceTree {
    /// Renders a bottom-up tree visualization centered within the given width.
    ///
    /// Choice nodes appear as circles sized by their shortlex complexity relative to their valid range. Smaller circles represent values closer to the semantic simplest (zero). Structural nodes (groups, sequences, branches, and so on) are invisible; only their branching connectors appear. Just nodes appear as small diamonds.
    ///
    /// ```swift
    /// let tree: ChoiceTree = .group([
    ///     .choice(.unsigned(5, .uint), ChoiceMetadata(validRange: 0...100)),
    ///     .choice(.unsigned(0, .uint), ChoiceMetadata(validRange: 0...100)),
    /// ])
    /// print(tree.visualization(width: 40))
    /// ```
    ///
    /// - Parameter width: The total character width of the output frame.
    /// - Returns: A multi-line string containing the Unicode tree visualization.
    func visualization(width: Int = 80) -> String {
        guard let renderTree = TreeVisualization.buildRenderTree(from: self) else {
            return TreeVisualization.centerLine("·", width: width)
        }
        if renderTree.children.isEmpty {
            return TreeVisualization.centerLine(
                String(renderTree.symbol ?? "·"),
                width: width
            )
        }
        let preferredSpacing = 4.0
        let minimumSpacing = 2.0
        var layout = TreeVisualization.computeLayout(renderTree, minSpacing: preferredSpacing)
        let naturalWidth = layout.subtreeRight - layout.subtreeLeft

        // Re-layout with tighter spacing if the tree overflows the frame
        if naturalWidth > Double(width - 1) && naturalWidth > 0 {
            let reducedSpacing = max(minimumSpacing, preferredSpacing * Double(width - 1) / naturalWidth)
            layout = TreeVisualization.computeLayout(renderTree, minSpacing: reducedSpacing)
        }

        return TreeVisualization.renderToString(layout, frameWidth: width)
    }
}

// MARK: - Implementation

/// Namespace for tree visualization internals.
private enum TreeVisualization {

    // MARK: Complexity Tier

    /// Maps a choice value's shortlex distance from zero to one of five visual tiers.
    enum ComplexityTier: Int {
        case minimal = 0
        case low = 1
        case moderate = 2
        case high = 3
        case extreme = 4

        var symbol: Character {
            switch self {
            case .minimal: "·"  // U+00B7
            case .low:     "∘"  // U+2218
            case .moderate: "✦" // U+2726
            case .high:    "✳" // U+2733
            case .extreme: "❋" // U+274B
            }
        }

        static func forChoice(
            _ value: ChoiceValue,
            metadata: ChoiceMetadata
        ) -> ComplexityTier {
            let key = value.shortlexKey
            if key == 0 {
                return .minimal
            }
            guard let range = metadata.validRange else {
                return absoluteTier(key)
            }

            let tag = value.tag
            let lowerKey = ChoiceValue(
                tag.makeConvertible(bitPattern64: range.lowerBound),
                tag: tag
            ).shortlexKey
            let upperKey = ChoiceValue(
                tag.makeConvertible(bitPattern64: range.upperBound),
                tag: tag
            ).shortlexKey
            let maxKey = max(lowerKey, upperKey)
            guard maxKey > 0 else {
                return .minimal
            }

            let fraction = Double(key) / Double(maxKey)
            return switch fraction {
            case ..<0.05: .low
            case ..<0.25: .moderate
            case ..<0.75: .high
            default:      .extreme
            }
        }

        private static func absoluteTier(_ key: UInt64) -> ComplexityTier {
            switch key {
            case 0:            .minimal
            case 1...10:       .low
            case 11...100:     .moderate
            case 101...10_000: .high
            default:           .extreme
            }
        }
    }

    // MARK: Render Tree

    /// An intermediate tree containing only the information needed for visualization.
    ///
    /// Invisible structural nodes have `symbol == nil`. Single-child invisible chains
    /// are collapsed so the tree is as shallow as possible.
    struct RenderTree {
        let symbol: Character?
        let children: [RenderTree]
    }

    static func buildRenderTree(from tree: ChoiceTree) -> RenderTree? {
        guard tree.hasVisibleContent else { return nil }
        return buildRenderNode(from: tree)
    }

    private static func buildRenderNode(from tree: ChoiceTree) -> RenderTree {
        switch tree {
        case let .choice(value, metadata):
            let tier = ComplexityTier.forChoice(value, metadata: metadata)
            return RenderTree(symbol: tier.symbol, children: [])

        case .just:
            return RenderTree(symbol: "✿", children: [])  // U+273F

        case .getSize:
            return RenderTree(symbol: nil, children: [])

        case let .selected(inner):
            return buildRenderNode(from: inner)

        case let .branch(_, _, _, _, choice):
            return collapseChain(
                RenderTree(symbol: nil, children: [buildRenderNode(from: choice)])
            )

        case let .group(array, _):
            let children = array.filter(\.hasVisibleContent).map(buildRenderNode)
            return collapseChain(RenderTree(symbol: nil, children: children))

        case let .sequence(_, elements, _):
            let children = elements.filter(\.hasVisibleContent).map(buildRenderNode)
            if children.isEmpty {
                return RenderTree(symbol: "·", children: [])
            }
            return collapseChain(RenderTree(symbol: nil, children: children))

        case let .bind(inner, bound):
            let children = [inner, bound]
                .filter(\.hasVisibleContent)
                .map(buildRenderNode)
            return collapseChain(RenderTree(symbol: nil, children: children))

        case let .resize(_, choices):
            let children = choices.filter(\.hasVisibleContent).map(buildRenderNode)
            return collapseChain(RenderTree(symbol: nil, children: children))
        }
    }

    /// Collapses single-child invisible chains so the tree has minimal depth.
    private static func collapseChain(_ node: RenderTree) -> RenderTree {
        var current = node
        while current.symbol == nil && current.children.count == 1 {
            current = current.children[0]
        }
        return current
    }

    // MARK: Layout

    /// A node with computed position and subtree bounds.
    struct LayoutNode {
        let symbol: Character?
        let column: Double
        let depth: Int
        let subtreeLeft: Double
        let subtreeRight: Double
        let children: [LayoutNode]

        func shifted(by offset: Double) -> LayoutNode {
            LayoutNode(
                symbol: symbol,
                column: column + offset,
                depth: depth,
                subtreeLeft: subtreeLeft + offset,
                subtreeRight: subtreeRight + offset,
                children: children.map { $0.shifted(by: offset) }
            )
        }
    }

    static func computeLayout(
        _ tree: RenderTree,
        minSpacing: Double
    ) -> LayoutNode {
        layoutSubtree(tree, depth: 0, minSpacing: minSpacing)
    }

    private static func layoutSubtree(
        _ node: RenderTree,
        depth: Int,
        minSpacing: Double
    ) -> LayoutNode {
        guard node.children.isEmpty == false else {
            return LayoutNode(
                symbol: node.symbol,
                column: 0,
                depth: depth,
                subtreeLeft: 0,
                subtreeRight: 0,
                children: []
            )
        }

        let childLayouts = node.children.map {
            layoutSubtree($0, depth: depth + 1, minSpacing: minSpacing)
        }

        // Place children side by side with minimum spacing
        var placedChildren: [LayoutNode] = []
        var cursor: Double = 0

        for (index, child) in childLayouts.enumerated() {
            let shift = cursor - child.subtreeLeft
            placedChildren.append(child.shifted(by: shift))
            if index < childLayouts.count - 1 {
                cursor = placedChildren.last!.subtreeRight + minSpacing
            }
        }

        // Center this node over its children
        let leftmostChildCol = placedChildren.first!.column
        let rightmostChildCol = placedChildren.last!.column
        let parentCol = (leftmostChildCol + rightmostChildCol) / 2.0

        return LayoutNode(
            symbol: node.symbol,
            column: parentCol,
            depth: depth,
            subtreeLeft: placedChildren.first!.subtreeLeft,
            subtreeRight: placedChildren.last!.subtreeRight,
            children: placedChildren
        )
    }

    // MARK: Rendering

    /// A node with integer screen coordinates ready for grid placement.
    struct PlacedNode {
        let symbol: Character?
        let column: Int
        let depth: Int
        let childInfos: [(column: Int, depth: Int)]
    }

    static func renderToString(_ layout: LayoutNode, frameWidth: Int) -> String {
        // Normalize to zero-origin
        let normalized = layout.shifted(by: -layout.subtreeLeft)
        let naturalWidth = normalized.subtreeRight

        // Scale columns proportionally if the tree still overflows after spacing reduction
        let fitted: LayoutNode
        if naturalWidth > Double(frameWidth - 1) && naturalWidth > 0 {
            let ratio = Double(frameWidth - 1) / naturalWidth
            fitted = scaleColumns(normalized, ratio: ratio)
        } else {
            fitted = normalized
        }

        // Center within width using integer offset to avoid systematic rightward rounding bias
        let maxColInt = Int(fitted.subtreeRight.rounded(.up))
        let intOffset = max(0, (frameWidth - 1 - maxColInt) / 2)
        let centered = fitted.shifted(by: Double(intOffset))
        let width = frameWidth

        // Flatten to integer-positioned nodes
        var nodes: [PlacedNode] = []
        flattenToPlaced(centered, into: &nodes)

        guard let maxDepth = nodes.map(\.depth).max() else {
            return ""
        }

        // Each depth level gets 2 screen rows: 1 symbol + 1 connector (branch bar)
        let rowsPerLevel = 2
        let totalHeight = maxDepth * rowsPerLevel + 1

        var grid = Array(
            repeating: Array(repeating: Character(" "), count: width),
            count: totalHeight
        )

        // Place visible node symbols
        for node in nodes {
            guard let symbol = node.symbol else { continue }
            let row = (maxDepth - node.depth) * rowsPerLevel
            placeChar(&grid, row: row, col: node.column, char: symbol, width: width)
        }

        // Draw pass-through at invisible nodes that have children
        for node in nodes where node.symbol == nil && node.childInfos.isEmpty == false {
            let row = (maxDepth - node.depth) * rowsPerLevel
            placeChar(&grid, row: row, col: node.column, char: "│", width: width)
        }

        // Draw connectors from each parent to its children
        for node in nodes where node.childInfos.isEmpty == false {
            let parentScreenRow = (maxDepth - node.depth) * rowsPerLevel
            let childScreenRow = (maxDepth - node.childInfos[0].depth) * rowsPerLevel
            let spec = ConnectionSpec(
                parentRow: parentScreenRow,
                parentCol: node.column,
                childRow: childScreenRow,
                childCols: node.childInfos.map(\.column),
                width: width
            )
            drawConnections(&grid, spec: spec)
        }

        // Convert grid to string, trimming trailing whitespace per line
        let lines = grid.map { row -> String in
            var chars = row
            while chars.last == " " {
                chars.removeLast()
            }
            return String(chars)
        }

        // Remove leading and trailing blank lines
        var result = lines
        while result.last?.isEmpty == true { result.removeLast() }
        while result.first?.isEmpty == true { result.removeFirst() }

        // Bonsai pot: find the trunk column from the last line, then replace it with the pot
        if let lastLine = result.last,
           let trunkIndex = lastLine.firstIndex(of: "│")
        {
            let trunkCol = lastLine.distance(from: lastLine.startIndex, to: trunkIndex)
            result.removeLast() // Remove the bottom │ — the pot rim's ┷ serves as trunk termination
            let potWidth = 9
            let halfPot = potWidth / 2
            let rimLeft = max(0, trunkCol - halfPot)

            // Rim: ━━━━┷━━━━
            var rim = String(repeating: " ", count: rimLeft)
            for col in rimLeft..<(rimLeft + potWidth) {
                rim.append(col == trunkCol ? "┷" : "━")
            }
            result.append(rim)

            // Base: ┗━━━━━━━┛ (inset by 1 on each side)
            let baseWidth = potWidth - 2
            var base = String(repeating: " ", count: rimLeft)
            base.append("┗")
            base.append(String(repeating: "━", count: max(0, baseWidth)))
            base.append("┛")
            result.append(base)
        }

        return result.joined(separator: "\n")
    }

    // MARK: Connector Drawing

    /// Bundles the parameters shared by connector-drawing routines.
    struct ConnectionSpec {
        let parentRow: Int
        let parentCol: Int
        let childRow: Int
        let childCols: [Int]
        let width: Int
    }

    private static func drawConnections(
        _ grid: inout [[Character]],
        spec: ConnectionSpec
    ) {
        guard spec.parentRow > spec.childRow + 1 else { return }

        // Single child: vertical stem only, no branch bar
        if spec.childCols.count == 1 {
            for row in (spec.childRow + 1)..<spec.parentRow {
                placeChar(&grid, row: row, col: spec.parentCol, char: "│", width: spec.width)
            }
            return
        }

        // Multiple children: branch bar directly under labels
        let barRow = spec.childRow + 1

        // Branch bar with junctions
        let sortedCols = spec.childCols.sorted()
        let leftmost = sortedCols.first!
        let rightmost = sortedCols.last!
        let childColSet = Set(sortedCols)

        for col in leftmost...rightmost {
            let isChild = childColSet.contains(col)
            let isParent = col == spec.parentCol
            let isLeftmost = col == leftmost
            let isRightmost = col == rightmost

            let char: Character
            if isChild && isParent {
                char = "┼"
            } else if isLeftmost && isChild {
                char = "╰"
            } else if isRightmost && isChild {
                char = "╯"
            } else if isChild {
                char = "┴"
            } else if isParent {
                char = "┬"
            } else {
                char = "─"
            }

            placeChar(&grid, row: barRow, col: col, char: char, width: spec.width)
        }

        // 3. Parent stem (from bar down to parent row)
        for row in (barRow + 1)..<spec.parentRow {
            placeChar(&grid, row: row, col: spec.parentCol, char: "│", width: spec.width)
        }
    }

    // MARK: Grid Helpers

    private static func placeChar(
        _ grid: inout [[Character]],
        row: Int,
        col: Int,
        char: Character,
        width: Int
    ) {
        guard row >= 0 && row < grid.count && col >= 0 && col < width else { return }
        if grid[row][col] == " " {
            grid[row][col] = char
        }
    }

    // MARK: Layout Helpers

    private static func flattenToPlaced(
        _ node: LayoutNode,
        into result: inout [PlacedNode]
    ) {
        let childInfo = node.children.map {
            (column: Int($0.column.rounded()), depth: $0.depth)
        }
        result.append(PlacedNode(
            symbol: node.symbol,
            column: Int(node.column.rounded()),
            depth: node.depth,
            childInfos: childInfo
        ))
        for child in node.children {
            flattenToPlaced(child, into: &result)
        }
    }

    private static func scaleColumns(
        _ node: LayoutNode,
        ratio: Double
    ) -> LayoutNode {
        LayoutNode(
            symbol: node.symbol,
            column: node.column * ratio,
            depth: node.depth,
            subtreeLeft: node.subtreeLeft * ratio,
            subtreeRight: node.subtreeRight * ratio,
            children: node.children.map { scaleColumns($0, ratio: ratio) }
        )
    }

    static func centerLine(_ text: String, width: Int) -> String {
        let padding = max(0, (width - text.count) / 2)
        return String(repeating: " ", count: padding) + text
    }
}

// MARK: - ChoiceTree Visible Content Check

private extension ChoiceTree {
    var hasVisibleContent: Bool {
        switch self {
        case .choice, .just:
            return true
        case .getSize:
            return false
        case let .selected(inner):
            return inner.hasVisibleContent
        case let .branch(_, _, _, _, choice):
            return choice.hasVisibleContent
        case let .group(children, _):
            return children.contains(where: \.hasVisibleContent)
        case let .sequence(_, elements, _):
            return elements.isEmpty || elements.contains(where: \.hasVisibleContent)
        case let .bind(inner, bound):
            return inner.hasVisibleContent || bound.hasVisibleContent
        case let .resize(_, choices):
            return choices.contains(where: \.hasVisibleContent)
        }
    }
}
