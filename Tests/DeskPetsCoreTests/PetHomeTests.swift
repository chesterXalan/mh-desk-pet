import CoreGraphics
import Foundation
import Testing
@testable import DeskPetsCore

@Suite struct PetHomeTests {
    private let laptop = CGRect(x: 0, y: 40, width: 1440, height: 835)
    private let external = CGRect(x: 1440, y: 0, width: 1920, height: 1080)

    @Test func legacyConfigKeepsFreePlacementAndHomeDefaults() throws {
        let old = Data("{\"petSize\":128,\"language\":\"ja\",\"animationDuration\":1.2}".utf8)
        let config = try JSONDecoder().decode(AppConfig.self, from: old)
        #expect(!config.home.enabled)
        #expect(config.home.showsGrid && config.home.automaticallyAssign)
        #expect(config.home.columns == 4)
        #expect(config.home.rows == 2)
        #expect(config.petSize == 128 && config.language == .japanese && config.animationDuration == 1.2)
        let draft = Data("{\"home\":{\"enabled\":true,\"columns\":3,\"x\":50,\"y\":80}}".utf8)
        let migrated = try JSONDecoder().decode(AppConfig.self, from: draft)
        #expect(migrated.home.enabled && migrated.home.columns == 3 && migrated.home.rows == 2)
        #expect(migrated.home.x == 50 && migrated.home.y == 80)
    }

    @Test func automaticResidentsKeepRoomsAcrossRefreshesAndNewArrivals() {
        var home = enabledHome()
        let ids = (0..<6).map { _ in UUID() }
        home.reconcile(active: Array(ids.prefix(4)), capacity: 8)
        let first = home.slots
        home.reconcile(active: Array(ids.prefix(4).reversed()), capacity: 8)
        #expect(home.slots == first)
        home.reconcile(active: [ids[0], ids[2], ids[3], ids[4]], capacity: 8)
        #expect(home.slots[0] == ids[0] && home.slots[2] == ids[2] && home.slots[3] == ids[3])
        #expect(home.slots[1] == ids[4])
        home.reconcile(active: ids, capacity: 8)
        #expect(Set(home.slots.compactMap { $0 }) == Set(ids))
        #expect(home.slots.compactMap { $0 }.count == ids.count)
    }

    @Test func residentsSwapAndCanMoveIntoEmptyRooms() {
        var home = enabledHome()
        let a = UUID(), b = UUID()
        home.reconcile(active: [a, b], capacity: 8)
        #expect(home.place(a, in: 1, active: [a, b], capacity: 8) == nil)
        #expect(home.slots[0] == b && home.slots[1] == a)
        home.place(a, in: 6, active: [a, b], capacity: 8)
        #expect(home.slots[1] == nil && home.slots[6] == a)
        #expect(home.slots[0] == b)
    }

    @Test func outsideSwapReturnsDisplacedPetAndDoesNotPullEitherBack() {
        var home = enabledHome()
        let a = UUID(), b = UUID(), c = UUID()
        home.reconcile(active: [a, b, c], capacity: 8)
        home.leave(c)
        #expect(home.place(c, in: 0, active: [a, b, c], capacity: 8) == a)
        home.reconcile(active: [a, b, c], capacity: 8)
        #expect(home.slots[0] == c && home.slots[1] == b)
        #expect(home.slot(for: a, capacity: 8) == nil)
        #expect(home.outside == [a])
        home.leave(c)
        home.reconcile(active: [a, b, c], capacity: 8)
        #expect(home.slot(for: c, capacity: 8) == nil)
        home.reconcile(active: [a, b, c], capacity: 8, moveAll: true)
        #expect(home.outside.isEmpty)
        #expect(Set(home.slots.compactMap { $0 }) == [a, b, c])
    }

    @Test func manualModeOnlyAcceptsDraggedOrExplicitlyInvitedPets() {
        var home = enabledHome()
        home.automaticallyAssign = false
        let a = UUID(), b = UUID()
        home.reconcile(active: [a, b], capacity: 8)
        #expect(home.slots.allSatisfy { $0 == nil })
        home.place(a, in: 4, active: [a, b], capacity: 8)
        home.reconcile(active: [a, b], capacity: 8)
        #expect(home.slots[4] == a)
        #expect(home.slot(for: b, capacity: 8) == nil)
        home.reconcile(active: [a, b], capacity: 8, moveAll: true)
        #expect(home.slot(for: b, capacity: 8) != nil)
        #expect(!home.automaticallyAssign)
    }

    @Test func overflowStaysOutsideAndCanUseVacanciesAfterReducingCapacity() {
        var home = enabledHome()
        let ids = (0..<8).map { _ in UUID() }
        home.reconcile(active: ids, capacity: 8)
        home.reconcile(active: Array(ids.dropFirst()), capacity: 4)
        #expect(home.slots[0] == ids[4])
        #expect(home.slots[1] == ids[1] && home.slots[2] == ids[2] && home.slots[3] == ids[3])
        #expect(home.slot(for: ids[5], capacity: 4) == nil)
        #expect(home.place(ids[5], in: 1, active: Set(ids.dropFirst()), capacity: 4) == ids[1])
        #expect(home.slots[1] == ids[5])
        #expect(home.outside.contains(ids[1]))
        #expect(home.slots.filter { $0 == ids[5] }.count == 1)
        #expect(home.slots.count == 4)
    }

    @Test func fixedGridDoesNotGrowWhenMoreSessionsArrive() {
        var home = enabledHome()
        let ids = (0..<12).map { _ in UUID() }
        let layout = PetHomeLayout(home: home, petSize: 128, screens: [laptop])
        #expect(layout.columns == 4 && layout.rows == 2 && layout.capacity == 8)
        home.reconcile(active: ids, capacity: layout.capacity)
        #expect(home.slots.count == 8)
        #expect(home.slots.compactMap { $0 } == Array(ids.prefix(8)))
        #expect(ids.suffix(4).allSatisfy { home.slot(for: $0, capacity: 8) == nil })
        home.rows = 3
        let expanded = PetHomeLayout(home: home, petSize: 128, screens: [laptop])
        home.reconcile(active: ids, capacity: expanded.capacity)
        #expect(home.slots.compactMap { $0 } == ids)
    }

    @Test func largeGridScalesRoomsWithoutChangingChosenDimensions() {
        var home = enabledHome()
        home.columns = 8
        home.rows = 8
        let layout = PetHomeLayout(home: home, petSize: 320, screens: [laptop])
        #expect(layout.capacity == 64 && layout.columns == 8 && layout.rows == 8)
        #expect(layout.cellSize < 320)
        #expect(laptop.contains(layout.frame))
    }

    @Test func overflowAvoidsHomeAndKeepsExistingOutsidePositions() {
        let home = CGRect(x: 700, y: 80, width: 600, height: 400)
        let inside = CGRect(x: 800, y: 100, width: 96, height: 96)
        let origin = PetPlacement.outsideOrigin(for: inside, avoiding: home, screens: [laptop])
        let placed = CGRect(origin: origin, size: inside.size)
        #expect(laptop.contains(placed))
        #expect(placed.intersection(home).width == 0 || placed.intersection(home).height == 0 || !placed.intersects(home))
        let outside = CGRect(x: 100, y: 100, width: 96, height: 96)
        #expect(PetPlacement.outsideOrigin(for: outside, avoiding: home, screens: [laptop]) == outside.origin)
    }

    @Test func restartedSessionReusesItsRoomWithoutChangingFreePositions() throws {
        let first = AgentSession(provider: .codex, pid: 1, startTime: 1, cwd: "/project")
        let second = AgentSession(provider: .claude, pid: 2, startTime: 2, cwd: "/project")
        var config = AppConfig(home: enabledHome())
        _ = BindingResolver.resolve(&config, sessions: [first, second], characters: ["a", "b"], choose: { $0.first })
        for (index, binding) in config.bindings.enumerated() {
            config.setPosition(binding.id, x: Double(20 + index * 100), y: 60)
        }
        let positions = config.directoryPositions
        let firstID = config.bindings[0].id, secondID = config.bindings[1].id
        config.home.reconcile(active: [firstID, secondID], capacity: 8)
        config.home.place(firstID, in: 5, active: [firstID, secondID], capacity: 8)
        config.home.x = 150
        config.home.y = 200
        _ = BindingResolver.resolve(&config, sessions: [second], characters: ["a", "b"])
        config = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config))
        let restarted = AgentSession(provider: .codex, pid: 3, startTime: 3, cwd: "/project")
        _ = BindingResolver.resolve(&config, sessions: [second, restarted], characters: ["a", "b"], choose: { $0.first })
        config.home.reconcile(active: config.bindings.map(\.id), capacity: 8)
        #expect(config.bindings.last?.id == firstID)
        #expect(config.home.slots[5] == firstID && config.home.slots[1] == secondID)
        #expect(config.directoryPositions == positions)
        #expect(config.home.x == 150 && config.home.y == 200)
    }

    @Test(arguments: [64, 96, 128, 192, 256])
    func layoutFitsDisplayAndDropTargetsMatchEveryRoom(size: Int) {
        var home = enabledHome()
        home.x = 1550
        home.y = 60
        let layout = PetHomeLayout(home: home, petSize: CGFloat(size) * 1.35, screens: [laptop, external])
        #expect(external.contains(layout.frame))
        for index in 0..<layout.capacity {
            let cell = layout.cell(index)
            #expect(layout.frame.contains(cell))
            #expect(layout.slot(at: CGPoint(x: cell.midX, y: cell.midY)) == index)
            let origin = layout.origin(for: index, petSize: CGFloat(size))
            #expect(cell.contains(CGRect(origin: origin, size: CGSize(width: CGFloat(size), height: CGFloat(size)))))
        }
        #expect(layout.slot(at: CGPoint(x: layout.frame.midX, y: layout.frame.maxY - 5)) == nil)
        #expect(layout.slot(at: CGPoint(x: layout.frame.maxX + 10, y: layout.frame.midY)) == nil)
    }

    @Test func unpluggingDisplayMovesWholeHomeAndPreservesRoomOrder() {
        var home = enabledHome()
        home.x = 1800
        home.y = 100
        let before = PetHomeLayout(home: home, petSize: 128, screens: [laptop, external])
        let after = PetHomeLayout(home: home, petSize: 128, screens: [laptop])
        #expect(laptop.contains(after.frame))
        #expect(before.columns == after.columns && before.rows == after.rows)
        let delta = CGPoint(x: after.frame.minX - before.frame.minX, y: after.frame.minY - before.frame.minY)
        for index in 0..<after.capacity {
            #expect(before.cell(index).offsetBy(dx: delta.x, dy: delta.y) == after.cell(index))
        }
        home.showsGrid = false
        #expect(PetHomeLayout(home: home, petSize: 128, screens: [laptop]) == after)
    }

    @Test func groupCanCrossDisplaysBeforeClampingAtEndOfDrag() {
        var home = enabledHome()
        home.x = -180
        home.y = -30
        let during = PetHomeLayout(home: home, petSize: 128, screens: [laptop], constrain: false)
        let ended = PetHomeLayout(home: home, petSize: 128, screens: [laptop])
        #expect(during.frame.origin == CGPoint(x: -180, y: -30))
        #expect(laptop.contains(ended.frame))
        #expect(during.frame.size == ended.frame.size)
    }

    private func enabledHome() -> PetHome {
        var home = PetHome()
        home.enabled = true
        return home
    }
}
