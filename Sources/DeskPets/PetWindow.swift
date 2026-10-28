import AppKit
import DeskPetsCore
import ImageIO
import QuartzCore

/// Decoded GIF frames, played by Core Animation so the app itself does no per-frame work.
final class GIFAnimation {
    let frames: [CGImage]
    let keyTimes: [NSNumber]
    let duration: CFTimeInterval

    private static var cache: [String: GIFAnimation] = [:]

    private init(frames: [CGImage], delays: [Double]) {
        self.frames = frames
        duration = delays.reduce(0, +)
        var elapsed = 0.0
        var times: [NSNumber] = [0]
        for delay in delays {
            elapsed += delay
            times.append(NSNumber(value: elapsed / duration))
        }
        keyTimes = times
    }

    static func load(_ url: URL) -> GIFAnimation? {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        let key = "\(url.path)|\(modified.timeIntervalSince1970)"
        if let cached = cache[key] { return cached }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        var frames: [CGImage] = []
        var delays: [Double] = []
        for index in 0..<CGImageSourceGetCount(source) {
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
            frames.append(image)
            delays.append(delay < 0.02 ? 0.1 : delay)  // browsers treat tiny delays as 100 ms too
        }
        guard !frames.isEmpty else { return nil }
        let animation = GIFAnimation(frames: frames, delays: delays)
        cache[key] = animation
        return animation
    }

    func play(on layer: CALayer, duration overrideDuration: Double? = nil) {
        layer.removeAnimation(forKey: "gif")
        layer.contents = frames[0]
        guard frames.count > 1 else { return }
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = frames
        animation.keyTimes = keyTimes
        animation.duration = overrideDuration ?? duration
        animation.calculationMode = .discrete
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: "gif")
    }
}

final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PetWindowController: NSObject, NSWindowDelegate {
    let bindingId: UUID
    var onMoved: ((UUID, CGPoint) -> Void)?
    var onDragBegan: ((UUID, CGPoint) -> Void)?
    var onDragEnded: ((UUID, CGPoint) -> Void)?
    var menuProvider: ((UUID) -> NSMenu)?

    private let panel: PetPanel
    private let petView: PetView
    private let bubble = HoverBubble()
    private var session: AgentSession?
    private var animation: GIFAnimation?
    private var animationDuration: Double?
    private var wantsVisible = false

    init(bindingId: UUID, origin: CGPoint, size: CGFloat) {
        self.bindingId = bindingId
        panel = PetPanel(contentRect: NSRect(origin: origin, size: NSSize(width: size, height: size)),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        petView = PetView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.contentView = petView
        panel.delegate = self
        petView.onDoubleClick = { [weak self] in self?.activateTerminal() }
        petView.onHover = { [weak self] inside in self?.hover(inside) }
        petView.onDragBegan = { [weak self] origin in
            guard let self else { return }
            self.onDragBegan?(self.bindingId, origin)
        }
        petView.onDragEnded = { [weak self] point in
            guard let self else { return }
            self.onDragEnded?(self.bindingId, point)
        }
        petView.onDragged = { [weak self] point in
            guard let self else { return }
            self.onMoved?(self.bindingId, point)
        }
        petView.setAccessibilityElement(true)
        petView.setAccessibilityRole(.image)
        petView.setAccessibilityIdentifier("pet-\(bindingId.uuidString)")
        petView.menuProvider = { [weak self] in
            guard let self else { return nil }
            return self.menuProvider?(self.bindingId)
        }
    }

    var frame: NSRect { panel.frame }

    func update(session: AgentSession, character: CharacterInfo, size: CGFloat, animationDuration: Double?,
                constrainToScreen: Bool = true) {
        self.session = session
        if panel.frame.width != size {
            panel.setFrame(NSRect(origin: panel.frame.origin, size: NSSize(width: size, height: size)), display: true)
        }
        if constrainToScreen { keepOnScreen() }
        petView.setAccessibilityLabel(character.displayName(in: L.language))
        petView.setState(session.state)
        let next = GIFAnimation.load(character.gif(for: session.state))
        if next !== animation || self.animationDuration != animationDuration {
            animation = next
            self.animationDuration = animationDuration
            restartAnimation()
        }
        let title = session.title.flatMap { $0.isEmpty ? nil : $0 }
        let detail = title == nil ? session.provider.rawValue : session.folderName
        bubble.text = "\(title ?? session.folderName)\n\(detail) · \(stateName(session.state))"
    }

    func keepOnScreen() {
        let origin = PetPlacement.visibleOrigin(for: panel.frame, screens: NSScreen.screens.map(\.visibleFrame))
        guard origin != panel.frame.origin else { return }
        setOrigin(origin)
        onMoved?(bindingId, origin)
    }

    func setOrigin(_ origin: CGPoint) {
        guard panel.frame.origin != origin else { return }
        panel.setFrameOrigin(origin)
        bubble.hide()
    }

    func show() {
        guard !wantsVisible else { return }
        wantsVisible = true
        panel.orderFrontRegardless()
        restartAnimation()
    }

    func hide() {
        guard wantsVisible else { return }
        wantsVisible = false
        bubble.hide()
        petView.sprite.removeAllAnimations()
        panel.orderOut(nil)
    }

    func close() {
        hide()
        panel.close()
    }

    func activateTerminal() {
        guard let session else { return }
        TerminalFocus.focus(session)
    }

    private func restartAnimation() {
        guard wantsVisible else {
            petView.sprite.removeAllAnimations()
            return
        }
        animation?.play(on: petView.sprite, duration: animationDuration)
    }

    private func hover(_ inside: Bool) {
        if inside { bubble.show(above: panel.frame) } else { bubble.hide() }
    }

    private func stateName(_ state: PetState) -> String {
        switch state {
        case .working: return L.t("state.working")
        case .waiting: return L.t("state.waiting")
        case .idle: return L.t("state.idle")
        case .unknown, .exited: return L.t("state.noHooks")
        }
    }

    // MARK: NSWindowDelegate

    func windowDidMove(_ notification: Notification) {
        bubble.hide()
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        if panel.occlusionState.contains(.visible) {
            if wantsVisible { animation?.play(on: petView.sprite, duration: animationDuration) }
        } else {
            petView.sprite.removeAllAnimations()
        }
    }
}

final class PetView: NSView {
    let sprite = CALayer()
    private let dot = CALayer()
    var onDoubleClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    var onDragBegan: ((CGPoint) -> Void)?
    var onDragEnded: ((CGPoint) -> Void)?
    var onDragged: ((CGPoint) -> Void)?
    var menuProvider: (() -> NSMenu?)?
    private var dragStart: (mouse: CGPoint, origin: CGPoint)?
    private var dragging = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = .clear
        sprite.contentsGravity = .resizeAspect
        sprite.magnificationFilter = .nearest
        sprite.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        dot.cornerRadius = 4
        dot.borderWidth = 1
        dot.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        dot.actions = ["backgroundColor": NSNull(), "position": NSNull(), "bounds": NSNull()]
        layer?.addSublayer(sprite)
        layer?.addSublayer(dot)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        sprite.frame = bounds
        dot.frame = NSRect(x: bounds.maxX - 10, y: 2, width: 8, height: 8)
    }

    func setState(_ state: PetState) {
        switch state {
        case .working: dot.backgroundColor = NSColor.systemGreen.cgColor
        case .waiting: dot.backgroundColor = NSColor.systemOrange.cgColor
        case .idle: dot.backgroundColor = NSColor.systemGray.cgColor
        case .unknown, .exited: dot.backgroundColor = nil
        }
        dot.borderWidth = dot.backgroundColor == nil ? 0 : 1
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }

    override func mouseExited(with event: NSEvent) { onHover?(false) }

    override func mouseDown(with event: NSEvent) {
        dragStart = nil
        dragging = false
        if event.clickCount == 2 {
            onDoubleClick?()
        } else if let window {
            onHover?(false)
            dragStart = (NSEvent.mouseLocation, window.frame.origin)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let mouse = NSEvent.mouseLocation
        let delta = CGPoint(x: mouse.x - start.mouse.x, y: mouse.y - start.mouse.y)
        guard dragging || hypot(delta.x, delta.y) >= 3 else { return }
        if !dragging {
            dragging = true
            onDragBegan?(start.origin)
        }
        window?.setFrameOrigin(CGPoint(x: start.origin.x + delta.x, y: start.origin.y + delta.y))
        if let window { onDragged?(window.frame.origin) }
    }

    override func mouseUp(with event: NSEvent) {
        if dragging { onDragEnded?(NSEvent.mouseLocation) }
        dragStart = nil
        dragging = false
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menuProvider?() else { return }
        onHover?(false)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

/// A small label shown above a pet on hover. It never takes mouse events.
@MainActor
final class HoverBubble {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")

    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let background = NSVisualEffectView()
        background.material = .toolTip
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 6
        label.font = .systemFont(ofSize: 11)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: background.topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -4),
        ])
        panel.contentView = background
    }

    func show(above frame: NSRect) {
        let size = panel.contentView!.fittingSize
        panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.maxY + 4, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }
}
