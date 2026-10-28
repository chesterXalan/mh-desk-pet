import AppKit
import DeskPetsCore

/// 宿舍以完整框線取得視窗焦點，小把手在隱藏格線時也能選取與搬家。
@MainActor
final class PetHomeWindowController: NSObject, NSWindowDelegate {
    var onDrag: ((CGPoint, Bool) -> Void)?
    var menuProvider: (() -> NSMenu)?

    private let background = PetHomeWindow(contentRect: .zero, styleMask: [.titled, .resizable, .fullSizeContentView],
                                           backing: .buffered, defer: true)
    private let handle = PetPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: true)
    private let grid = PetHomeGridView()
    private let grip = PetHomeHandleView()
    private var layout: PetHomeLayout?
    private var dragOrigin: CGPoint?
    private var renderedFrame = CGRect.zero
    private var updating = false
    private var externalMove: DispatchWorkItem?

    override init() {
        super.init()
        for panel in [background, handle] {
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        }
        background.delegate = self
        background.isMovable = true
        background.titleVisibility = .hidden
        background.titlebarAppearsTransparent = true
        background.standardWindowButton(.closeButton)?.isHidden = true
        background.standardWindowButton(.miniaturizeButton)?.isHidden = true
        background.standardWindowButton(.zoomButton)?.isHidden = true
        background.setAccessibilityElement(true)
        background.setAccessibilitySubrole(.standardWindow)
        background.setAccessibilityIdentifier("pet-home-window")
        background.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        background.contentView = grid
        handle.level = .floating
        handle.contentView = grip
        grip.onDrag = { [weak self] delta, ended in
            guard let self, let layout = self.layout else { return }
            let origin = self.dragOrigin ?? layout.frame.origin
            self.dragOrigin = ended ? nil : origin
            self.onDrag?(CGPoint(x: origin.x + delta.x, y: origin.y + delta.y), ended)
        }
        grid.onSelect = { [weak self] in self?.selectHome() }
        grid.menuProvider = { [weak self] in self?.menuProvider?() ?? NSMenu() }
        grip.onSelect = { [weak self] in self?.selectHome() }
        grip.menuProvider = { [weak self] in self?.menuProvider?() ?? NSMenu() }
    }

    func update(layout: PetHomeLayout, occupied: Set<Int>, showsGrid: Bool, visible: Bool, preview: PetHomeEdge?) {
        if !visible {
            externalMove?.cancel()
            externalMove = nil
        }
        guard externalMove == nil else { return }
        updating = true
        defer { updating = false }
        self.layout = layout
        let displayFrame = preview.map { layout.expandedFrame(toward: $0) } ?? layout.frame
        background.title = L.t("home.title")
        background.setFrame(displayFrame, display: true)
        renderedFrame = background.frame
        background.ignoresMouseEvents = !showsGrid
        grid.showsGrid = showsGrid
        grid.cells = (0..<layout.capacity).map {
            layout.cell($0).offsetBy(dx: -displayFrame.minX, dy: -displayFrame.minY)
        }
        grid.previewCells = preview.map { edge in
            layout.expansionCells(toward: edge).map { $0.offsetBy(dx: -displayFrame.minX, dy: -displayFrame.minY) }
        } ?? []
        grid.occupied = occupied
        grid.needsDisplay = true
        let width = min(240, displayFrame.width - 12)
        handle.setFrame(NSRect(x: displayFrame.midX - width / 2,
                               y: displayFrame.maxY - PetHomeLayout.headerHeight + 2,
                               width: width, height: 28), display: true)
        grip.title = L.format("home.handle", occupied.count, layout.capacity)
        grip.selected = background.isKeyWindow && NSApp.isActive
        grip.toolTip = L.t("home.dragHelp")
        grip.setAccessibilityLabel(grip.title)
        grip.setAccessibilityHelp(L.t("home.dragHelp"))
        if visible {
            background.orderFrontRegardless()
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
        externalMove?.cancel()
        externalMove = nil
        background.orderOut(nil)
        handle.orderOut(nil)
    }

    private func selectHome() {
        NSApp.activate()
        background.makeKeyAndOrderFront(nil)
        background.orderFrontRegardless()
    }

    func windowDidBecomeKey(_ notification: Notification) { grip.selected = true }
    func windowDidResignKey(_ notification: Notification) { grip.selected = false }
    func windowDidMove(_ notification: Notification) { scheduleExternalMove() }
    func windowDidResize(_ notification: Notification) { scheduleExternalMove() }

    private func scheduleExternalMove() {
        guard !updating, background.isVisible, layout != nil, background.frame != renderedFrame else { return }
        externalMove?.cancel()
        // 視窗管理工具可能分開設定座標與尺寸，合併完成後再帶整組移動。
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.externalMove = nil
            guard self.background.isVisible, let layout = self.layout else { return }
            let delta = CGPoint(x: self.background.frame.minX - self.renderedFrame.minX,
                                y: self.background.frame.minY - self.renderedFrame.minY)
            self.onDrag?(CGPoint(x: layout.frame.minX + delta.x, y: layout.frame.minY + delta.y), true)
        }
        externalMove = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }
}

private final class PetHomeWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class PetHomeGridView: NSView {
    var cells: [CGRect] = []
    var previewCells: [CGRect] = []
    var occupied: Set<Int> = []
    var highlighted: Int?
    var showsGrid = true
    var onSelect: (() -> Void)?
    var menuProvider: (() -> NSMenu)?

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onSelect?() }

    override func rightMouseDown(with event: NSEvent) {
        onSelect?()
        guard let menu = menuProvider?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill(using: .copy)
        guard showsGrid else { return }
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
        for rect in previewCells {
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 12, yRadius: 12)
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
            path.fill()
            NSColor.controlAccentColor.withAlphaComponent(0.9).setStroke()
            path.lineWidth = 2
            path.setLineDash([6, 4], count: 2, phase: 0)
            path.stroke()
            let label = "+" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 24, weight: .light), .foregroundColor: NSColor.controlAccentColor,
            ]
            let size = label.size(withAttributes: attributes)
            label.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                       withAttributes: attributes)
        }
    }
}

private final class PetHomeHandleView: NSView {
    var title = "" { didSet { needsDisplay = true } }
    var selected = false { didSet { needsDisplay = true } }
    var onSelect: (() -> Void)?
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
        (selected ? NSColor.controlAccentColor : NSColor.labelColor.withAlphaComponent(0.2)).setStroke()
        path.lineWidth = selected ? 2 : 1
        path.stroke()
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        ("⠿  " + title as NSString).draw(in: bounds.insetBy(dx: 8, dy: 6), withAttributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ])
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?()
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
        onSelect?()
        guard let menu = menuProvider?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}
