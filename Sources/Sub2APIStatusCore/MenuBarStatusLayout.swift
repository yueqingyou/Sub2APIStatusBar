import Foundation

public struct MenuBarStatusLayout: Sendable, Equatable {
    public static let fallbackWidth: Double = 128
    public static let fixedHeight: Double = 22
    public static let topRowHeight: Double = 13
    public static let bottomRowHeight: Double = 9
    public static let separatorWidth: Double = 1
    public static let separatorSpacing: Double = 2
    public static let separatorHeight: Double = 16

    public let cells: [MenuBarStatusCell]
    public let topRow: String
    public let bottomRow: String
    public let width: Double
    public let height: Double
    public let topRowHeight: Double
    public let bottomRowHeight: Double

    public init(
        cells: [MenuBarStatusCell] = [],
        topRow: String,
        bottomRow: String,
        width: Double = Self.fallbackWidth,
        height: Double = Self.fixedHeight,
        topRowHeight: Double = Self.topRowHeight,
        bottomRowHeight: Double = Self.bottomRowHeight
    ) {
        self.cells = cells
        self.topRow = topRow
        self.bottomRow = bottomRow
        self.width = width
        self.height = height
        self.topRowHeight = topRowHeight
        self.bottomRowHeight = bottomRowHeight
    }

    public static func make(
        presentation: MenuBarStatusPresentation,
        fallbackTitle: String
    ) -> MenuBarStatusLayout {
        let trimmedFallback = fallbackTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let top = presentation.topRow.isEmpty ? trimmedFallback : presentation.topRow
        let bottom = presentation.bottomRow.isEmpty ? trimmedFallback : presentation.bottomRow
        let width = width(for: presentation.cells)
        return MenuBarStatusLayout(cells: presentation.cells, topRow: top, bottomRow: bottom, width: width)
    }

    private static func width(for cells: [MenuBarStatusCell]) -> Double {
        guard !cells.isEmpty else {
            return fallbackWidth
        }
        let cellWidth = cells.reduce(0) { $0 + $1.width }
        let separatorCount = max(cells.count - 1, 0)
        let separatorArea = Double(separatorCount) * (separatorWidth + separatorSpacing * 2)
        return cellWidth + separatorArea
    }
}
