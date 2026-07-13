import AppKit
import Sub2APIStatusCore

final class MenuBarStatusView: NSView {
    private var currentLayout = MenuBarStatusLayout.make(
        presentation: MenuBarStatusPresentation(title: "", hidesHealthyStatusImage: false),
        fallbackTitle: ""
    )
    private var cellViews: [MenuBarStatusCellView] = []
    private let fallbackCellView = MenuBarStatusCellView()
    private let separatorColor = NSColor(name: nil) { appearance in
        appearance.menuBarControlTextColor(alpha: 0.5)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func update(presentation: MenuBarStatusPresentation, fallbackTitle: String) {
        let nextLayout = MenuBarStatusLayout.make(
            presentation: presentation.fittedForMenuBar(),
            fallbackTitle: fallbackTitle
        )
        guard nextLayout != currentLayout else {
            return
        }
        currentLayout = nextLayout
        if currentLayout.cells.isEmpty {
            fallbackCellView.update(value: currentLayout.topRow, label: currentLayout.bottomRow)
        } else {
            configureCellViews(for: currentLayout.cells)
        }
        frame.size = fittingSize
        invalidateIntrinsicContentSize()
        needsLayout = true
        needsDisplay = true
    }

    private func setup() {
        wantsLayer = true
        addSubview(fallbackCellView)
    }

    private func configureCellViews(for cells: [MenuBarStatusCell]) {
        while cellViews.count < cells.count {
            let view = MenuBarStatusCellView()
            cellViews.append(view)
            addSubview(view)
        }
        for (index, cell) in cells.enumerated() {
            cellViews[index].update(value: cell.value, label: cell.label, valueTone: cell.valueTone)
            cellViews[index].isHidden = false
        }
        if cellViews.count > cells.count {
            for index in cells.count..<cellViews.count {
                cellViews[index].isHidden = true
            }
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: currentLayout.width, height: currentLayout.height)
    }

    override var fittingSize: NSSize {
        intrinsicContentSize
    }

    override func layout() {
        super.layout()
        if currentLayout.cells.isEmpty {
            fallbackCellView.isHidden = false
            fallbackCellView.frame = bounds
            cellViews.forEach { $0.isHidden = true }
            return
        }

        fallbackCellView.isHidden = true
        var x: CGFloat = 0
        let separatorWidth = CGFloat(MenuBarStatusLayout.separatorWidth)
        let separatorSpacing = CGFloat(MenuBarStatusLayout.separatorSpacing)
        for (index, cell) in currentLayout.cells.enumerated() {
            if index > 0 {
                x += separatorSpacing + separatorWidth + separatorSpacing
            }
            let width = CGFloat(cell.width)
            cellViews[index].frame = NSRect(x: x, y: 0, width: width, height: bounds.height)
            x += width
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !currentLayout.cells.isEmpty, currentLayout.cells.count > 1 else {
            return
        }
        separatorColor.setFill()
        var x: CGFloat = 0
        let separatorWidth = CGFloat(MenuBarStatusLayout.separatorWidth)
        let separatorSpacing = CGFloat(MenuBarStatusLayout.separatorSpacing)
        for (index, cell) in currentLayout.cells.enumerated() where index < currentLayout.cells.count - 1 {
            x += CGFloat(cell.width) + separatorSpacing
            let separatorHeight = CGFloat(MenuBarStatusLayout.separatorHeight)
            let rect = NSRect(
                x: x,
                y: (bounds.height - separatorHeight) / 2,
                width: separatorWidth,
                height: separatorHeight
            )
            rect.fill()
            x += separatorWidth + separatorSpacing
        }
    }
}

private final class MenuBarStatusCellView: NSView {
    private let topLabel = NSTextField(labelWithString: "")
    private let bottomLabel = NSTextField(labelWithString: "")
    private let primaryTextColor = NSColor(name: nil) { appearance in
        appearance.menuBarControlTextColor(alpha: 1)
    }
    private let secondaryTextColor = NSColor(name: nil) { appearance in
        appearance.menuBarControlTextColor(alpha: 0.82)
    }
    private let tertiaryTextColor = NSColor(name: nil) { appearance in
        appearance.menuBarControlTextColor(alpha: 0.6)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    func update(value: String, label: String, valueTone: MenuBarStatusCellTone = .primary) {
        if topLabel.stringValue != value {
            topLabel.stringValue = value
        }
        if bottomLabel.stringValue != label {
            bottomLabel.stringValue = label
        }
        let nextTopColor = valueTone == .primary ? primaryTextColor : tertiaryTextColor
        topLabel.textColor = nextTopColor
    }

    private func setup() {
        topLabel.alignment = .center
        bottomLabel.alignment = .center
        topLabel.lineBreakMode = .byTruncatingTail
        bottomLabel.lineBreakMode = .byTruncatingTail
        topLabel.font = MenuBarStatusMetrics.topFont
        bottomLabel.font = MenuBarStatusMetrics.bottomFont
        topLabel.textColor = primaryTextColor
        bottomLabel.textColor = secondaryTextColor
        topLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        bottomLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(topLabel)
        addSubview(bottomLabel)
    }

    override func layout() {
        super.layout()
        let topHeight = CGFloat(MenuBarStatusLayout.topRowHeight)
        let bottomHeight = CGFloat(MenuBarStatusLayout.bottomRowHeight)
        topLabel.frame = NSRect(x: 0, y: bounds.height - topHeight, width: bounds.width, height: topHeight)
        bottomLabel.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bottomHeight)
    }
}

private enum MenuBarStatusMetrics {
    static let topFont = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
    static let bottomFont = NSFont.systemFont(ofSize: 7)

    static func fittedCell(_ cell: MenuBarStatusCell) -> MenuBarStatusCell {
        let topWidth = (cell.value as NSString).size(withAttributes: [.font: topFont]).width
        let bottomWidth = (cell.label as NSString).size(withAttributes: [.font: bottomFont]).width
        return MenuBarStatusCell(
            value: cell.value,
            label: cell.label,
            width: cell.fittedWidth(contentWidth: Double(max(topWidth, bottomWidth))),
            valueTone: cell.valueTone
        )
    }
}

private extension MenuBarStatusPresentation {
    func fittedForMenuBar() -> MenuBarStatusPresentation {
        MenuBarStatusPresentation(
            title: title,
            cells: cells.map(MenuBarStatusMetrics.fittedCell),
            topRow: topRow,
            bottomRow: bottomRow,
            hidesHealthyStatusImage: hidesHealthyStatusImage
        )
    }
}

private extension NSAppearance {
    func menuBarControlTextColor(alpha: CGFloat) -> NSColor {
        var color = NSColor.controlTextColor.withAlphaComponent(alpha)
        performAsCurrentDrawingAppearance {
            color = NSColor.controlTextColor.withAlphaComponent(alpha)
        }
        return color
    }
}
