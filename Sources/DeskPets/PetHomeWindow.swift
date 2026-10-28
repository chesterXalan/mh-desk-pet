import AppKit
import DeskPetsCore

/// 背景穿透滑鼠，小把手獨立接收拖曳，隱藏格線時也能搬動宿舍。
@MainActor
final class PetHomeWindowController {
    var onDrag: ((CGPoint, Bool) -> Void)?
    var menuProvider: (() -> NSMenu)?

    private let background = PetPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                      backing: .buffered, defer: true)
    private let handle = PetPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: true)
    private let grid = PetHomeGridView()
    private let grip = PetHomeHandleView()
    private var layout: PetHomeLayout?
    private var dragOrigin: CGPoint?

    init() {
        for panel in [background, handle] {
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        }
        background.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        background.ignoresMouseEvents = true
        background.contentView = grid
        handle.level = .floating
        handle.contentView = grip
        grip.onDrag = { [weak self] delta, ended in
            guard let self, let layout = self.layout else { return }
            let origin = self.dragOrigin ?? layout.frame.origin
            self.dragOrigin = ended ? nil : origin
            self.onDrag?(CGPoint(x: origin.x + delta.x, y: origin.y + delta.y), ended)
        }
        grip.menuProvider = { [weak self] in self?.menuProvider?() ?? NSMenu() }
    }

    func update(layout: PetHomeLayout, occupied: Set<Int>, showsGrid: Bool, visible: Bool) {
        self.layout = layout
        background.setFrame(layout.frame, display: true)
        grid.cells = (0..<layout.capacity).map {
            layout.cell($0).offsetBy(dx: -layout.frame.minX, dy: -layout.frame.minY)
        }
        grid.occupied = occupied
        grid.needsDisplay = true
        let width = min(240, layout.frame.width - 12)
        handle.setFrame(NSRect(x: layout.frame.midX - width / 2,
                               y: layout.frame.maxY - PetHomeLayout.headerHeight + 2,
                               width: width, height: 28), display: true)
        grip.title = L.format("home.handle", occupied.count, layout.capacity)
        grip.toolTip = L.t("home.dragHelp")
        grip.setAccessibilityLabel(grip.title)
        grip.setAccessibilityHelp(L.t("home.dragHelp"))
        if visible {
            if showsGrid { background.orderFrontRegardless() } else { background.orderOut(nil) }
            handle.orderFrontRegardless()
        } else {
            background.orderOut(nil)
            handle.orderOut(nil)
        }
    }

    func highlight(_ index: Int?) {
        guard grid.highlighted != index else { return }
        grid.highlighted = index
        grid.needsDisplay = true
    }

    func hide() {
        background.orderOut(nil)
        handle.orderOut(nil)
    }
}

private final class PetHomeGridView: NSView {
    var cells: [CGRect] = []
    var occupied: Set<Int> = []
    var highlighted: Int?

    override func draw(_ dirtyRect: NSRect) {
        for (index, rect) in cells.enumerated() {
            let path = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
            let selected = highlighted == index
            (selected ? NSColor.controlAccentColor.withAlphaComponent(0.3)
                      : NSColor.windowBackgroundColor.withAlphaComponent(0.26)).setFill()
            path.fill()
            (selected ? NSColor.controlAccentColor.withAlphaComponent(0.9)
                      : NSColor.labelColor.withAlphaComponent(0.18)).setStroke()
            path.lineWidth = selected ? 2 : 1
            path.stroke()
            (String(index + 1) as NSString).draw(at: CGPoint(x: rect.minX + 9, y: rect.maxY - 21),
                withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
                                 .foregroundColor: NSColor.labelColor.withAlphaComponent(occupied.contains(index) ? 0.25 : 0.5)])
        }
    }
}

private final class PetHomeHandleView: NSView {
    var title = "" { didSet { needsDisplay = true } }
    var onDrag: ((CGPoint, Bool) -> Void)?
    var menuProvider: (() -> NSMenu)?
    private var start: CGPoint?
    private var dragging = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityIdentifier("pet-home-handle")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
        NSColor.windowBackgroundColor.withAlphaComponent(0.86).setFill()
        path.fill()
        NSColor.labelColor.withAlphaComponent(0.2).setStroke()
        path.stroke()
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        ("⠿  " + title as NSString).draw(in: bounds.insetBy(dx: 8, dy: 6), withAttributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ])
    }

    override func mouseDown(with event: NSEvent) {
        start = NSEvent.mouseLocation
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let mouse = NSEvent.mouseLocation
        dragging = true
        onDrag?(CGPoint(x: mouse.x - start.x, y: mouse.y - start.y), false)
    }

    override func mouseUp(with event: NSEvent) {
        if dragging, let start {
            let mouse = NSEvent.mouseLocation
            onDrag?(CGPoint(x: mouse.x - start.x, y: mouse.y - start.y), true)
        }
        start = nil
        dragging = false
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menuProvider?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}
