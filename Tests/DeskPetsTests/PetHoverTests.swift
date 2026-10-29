import AppKit
import Testing
@testable import DeskPets
@testable import DeskPetsCore

@Suite(.serialized) @MainActor struct PetHoverTests {
    @Test func refreshKeepsHoverVisibleAtFractionalPositions() throws {
        let scales: [CGFloat] = [1, 1.05, 1.08, 1.1, 1.12, 1.15, 1.2]
        for x: CGFloat in [100, -1800] {
            let layout = PetHomeLayout(frame: CGRect(x: x, y: 100, width: 548, height: 314),
                                       columns: 4, rows: 2, cellSize: 128)
            for scale in scales {
                let size = 96 * scale
                let origin = layout.origin(for: 0, petSize: size)
                try withPet(origin: origin, size: size) { pet, view, bubble in
                    let character = CharacterInfo(name: "test", directory: URL(fileURLWithPath: "/dev/null"),
                                                  builtIn: false)
                    let session = AgentSession(provider: .codex, pid: 1, startTime: 1, cwd: "/test", state: .idle)
                    @MainActor func refresh() {
                        pet.update(session: session, character: character, size: size,
                                   animationDuration: 1.2, constrainToScreen: false)
                        pet.setOrigin(origin)
                    }
                    refresh()
                    let actualOrigin = pet.frame.origin
                    view.onHover?(true)
                    #expect(bubble.isVisible)
                    for _ in 0..<3 {
                        refresh()
                        #expect(pet.frame.origin == actualOrigin)
                        #expect(bubble.isVisible)
                    }
                }
            }
        }
    }

    @Test func movementAndHoverExitStillDismissTheBubble() throws {
        try withPet(origin: CGPoint(x: 100.4, y: 100.4), size: 96) { pet, view, bubble in
            view.onHover?(true)
            #expect(bubble.isVisible)
            let previous = pet.frame.origin
            pet.setOrigin(CGPoint(x: previous.x + 20, y: previous.y + 20))
            #expect(pet.frame.origin != previous)
            #expect(!bubble.isVisible)

            view.onHover?(true)
            #expect(bubble.isVisible)
            view.onHover?(false)
            #expect(!bubble.isVisible)
        }
    }

    @Test func layoutUpdatesPreserveTheHoverTrackingArea() throws {
        let view = PetView(frame: CGRect(x: 0, y: 0, width: 96, height: 96))
        view.updateTrackingAreas()
        let area = try #require(view.trackingAreas.first)
        for size: CGFloat in [96, 100.8, 100.8, 128] {
            view.frame.size = CGSize(width: size, height: size)
            view.updateTrackingAreas()
            #expect(view.trackingAreas.count == 1)
            #expect(view.trackingAreas.first === area)
            #expect(area.options.contains(.inVisibleRect))
        }
    }

    @Test func habitatRefreshKeepsTheBubbleAboveItsHandle() throws {
        let app = NSApplication.shared
        let existing = Set(app.windows.map(ObjectIdentifier.init))
        let home = PetHomeWindowController()
        defer { home.hide() }
        let windows = app.windows.filter { !existing.contains(ObjectIdentifier($0)) }
        windows.forEach { $0.alphaValue = 0 }
        let handle = try #require(windows.first { $0 is PetPanel })
        let layout = PetHomeLayout(frame: CGRect(x: 100, y: 100, width: 548, height: 314),
                                   columns: 4, rows: 2, cellSize: 128)
        home.update(layout: layout, occupied: [1], showsGrid: true, visible: true, preview: nil)
        try withPet(origin: layout.origin(for: 1, petSize: 96), size: 96) { pet, view, bubble in
            pet.update(session: AgentSession(provider: .codex, pid: 1, startTime: 1, cwd: "/test", state: .idle),
                       character: CharacterInfo(name: "test", directory: URL(fileURLWithPath: "/dev/null"), builtIn: false),
                       size: 96, animationDuration: 1.2, constrainToScreen: false)
            view.onHover?(true)
            #expect(bubble.frame.intersects(handle.frame))
            for _ in 0..<3 {
                home.update(layout: layout, occupied: [1], showsGrid: true, visible: true, preview: nil)
                let ordered = NSWindow.windowNumbers(options: []) ?? []
                let bubbleIndex = try #require(ordered.firstIndex(of: NSNumber(value: bubble.windowNumber)))
                let handleIndex = try #require(ordered.firstIndex(of: NSNumber(value: handle.windowNumber)))
                #expect(bubbleIndex < handleIndex)
            }
        }
    }

    private func withPet(origin: CGPoint, size: CGFloat,
                         _ body: @MainActor (PetWindowController, PetView, NSPanel) throws -> Void) throws {
        let app = NSApplication.shared
        let existing = Set(app.windows.map(ObjectIdentifier.init))
        let pet = PetWindowController(bindingId: UUID(), origin: origin, size: size)
        defer { pet.close() }
        let windows = app.windows.filter { !existing.contains(ObjectIdentifier($0)) }
        let view = try #require(windows.compactMap { $0.contentView as? PetView }.first)
        let bubble = try #require(windows.compactMap { $0 as? NSPanel }.first { !($0 is PetPanel) })
        // Exercise real window visibility without displaying test windows on the user's desktop.
        bubble.alphaValue = 0
        defer { view.onHover?(false) }
        try body(pet, view, bubble)
    }
}
