import CoreGraphics
import Foundation
import Testing
@testable import DeskPetsCore

@Suite struct PetHomeResizingTests {
    private let screen = CGRect(x: 0, y: 0, width: 1600, height: 1200)
    private let petSize: CGFloat = 100

    @Test func legacyHabitatKeepsFixedSizeUntilOptedIn() throws {
        let data = Data("{\"enabled\":true,\"columns\":4,\"rows\":2,\"x\":150,\"y\":80}".utf8)
        var home = try JSONDecoder().decode(PetHome.self, from: data)
        #expect(!home.smartResize && home.expansion == PetHomeExpansion())
        let ids = (0..<10).map { _ in UUID() }
        let layout = home.arrange(active: ids, petSize: petSize, screens: [screen])
        #expect(layout.capacity == 8)
        #expect(home.slots.compactMap { $0 } == Array(ids.prefix(8)))
        #expect(home.x == 150 && home.y == 80)
    }

    @Test(arguments: PetHomeEdge.allCases)
    func expansionAndContractionPreserveEveryExistingRoom(edge: PetHomeEdge) throws {
        var home = smartHome()
        let ids = (0..<4).map { _ in UUID() }, newcomer = UUID()
        let before = home.arrange(active: ids, petSize: petSize, screens: [screen])
        let expandedResult = home.expand(toward: edge, layout: before, screens: [screen])
        let expanded = try #require(expandedResult)
        #expect(expanded.frame == before.expandedFrame(toward: edge))
        let previewCells = before.expansionCells(toward: edge)
        #expect(expanded.indices(on: edge).map { expanded.cell($0) } == previewCells)
        for (index, id) in ids.enumerated() {
            let room = try #require(home.slot(for: id, capacity: expanded.capacity))
            #expect(expanded.cell(room) == before.cell(index))
        }
        home.place(newcomer, in: expanded.indices(on: edge)[0], active: Set(ids + [newcomer]), capacity: expanded.capacity)
        home = try JSONDecoder().decode(PetHome.self, from: JSONEncoder().encode(home))
        let restored = home.arrange(active: ids + [newcomer], petSize: petSize, screens: [screen])
        #expect(restored == expanded)
        #expect(home.expansion[edge] == 1 && home.smartResize)
        home.leave(newcomer)
        let shrunk = home.arrange(active: ids + [newcomer], petSize: petSize, screens: [screen])
        #expect(shrunk == before)
        #expect(home.slots.compactMap { $0 } == ids)
        #expect(home.expansion == PetHomeExpansion())
        #expect(home.outside.contains(newcomer))
    }

    @Test(arguments: PetHomeEdge.allCases)
    func fullHabitatExpandsOnlyTowardAvailableSpace(edge: PetHomeEdge) throws {
        var home = smartHome()
        home.columns = 1
        home.rows = 1
        let first = UUID(), second = UUID()
        let before = home.arrange(active: [first], petSize: petSize, screens: [screen])
        let availableScreen = before.expandedFrame(toward: edge)
        #expect(before.preferredExpansion(home: home, screens: [availableScreen]) == edge)
        let after = home.arrange(active: [first, second], petSize: petSize, screens: [availableScreen])
        #expect(after.capacity == 2)
        #expect(home.expansion[edge] == 1)
        #expect(home.slot(for: second, capacity: 2) != nil)
        #expect(after.cell(try #require(home.slot(for: first, capacity: 2))) == before.cell(0))
        #expect(availableScreen.contains(after.frame))
    }

    @Test func automaticGrowthFavorsCompactShapeAndRoomierSide() throws {
        var home = smartHome()
        home.columns = 4
        let ids = (0..<9).map { _ in UUID() }
        let before = home.arrange(active: Array(ids.prefix(8)), petSize: petSize, screens: [screen])
        #expect(before.preferredExpansion(home: home, screens: [screen]) == .top)
        let after = home.arrange(active: ids, petSize: petSize, screens: [screen])
        #expect(after.columns == 4 && after.rows == 3)
        #expect(home.expansion.top == 1)
        for (index, id) in ids.prefix(8).enumerated() {
            #expect(after.cell(try #require(home.slot(for: id, capacity: after.capacity))) == before.cell(index))
        }
    }

    @Test func noSpaceLeavesOverflowOutsideWithoutShrinkingOrMovingExistingRooms() {
        var home = smartHome()
        let ids = (0..<5).map { _ in UUID() }
        let before = home.arrange(active: Array(ids.prefix(4)), petSize: petSize, screens: [screen])
        let after = home.arrange(active: ids, petSize: petSize, screens: [before.frame])
        #expect(after == before)
        #expect(home.slots.compactMap { $0 } == Array(ids.prefix(4)))
        #expect(home.slot(for: ids[4], capacity: after.capacity) == nil)
        #expect(home.expansion == PetHomeExpansion())
    }

    @Test func emptyInteriorAndOccupiedOuterRoomPreventShrinking() throws {
        var home = smartHome()
        let resident = UUID(), newcomer = UUID()
        let base = home.arrange(active: [resident], petSize: petSize, screens: [screen])
        let onceResult = home.expand(toward: .right, layout: base, screens: [screen])
        let once = try #require(onceResult)
        let twiceResult = home.expand(toward: .right, layout: once, screens: [screen])
        let twice = try #require(twiceResult)
        home.place(newcomer, in: twice.columns - 1, active: [resident, newcomer], capacity: twice.capacity)
        let occupied = home.arrange(active: [resident, newcomer], petSize: petSize, screens: [screen])
        #expect(occupied == twice)
        #expect(home.slots[2] == nil)
        let ended = home.arrange(active: [resident], petSize: petSize, screens: [screen])
        #expect(ended == base)
        #expect(home.columns == 2 && home.rows == 2)
        #expect(home.slots.filter { $0 != nil }.count == 1)
    }

    @Test(arguments: PetHomeEdge.allCases)
    func edgePreviewIsReadOnlyAndDroppingCommitsTheSameRoom(edge: PetHomeEdge) throws {
        var home = smartHome()
        home.automaticallyAssign = false
        let resident = UUID(), newcomer = UUID()
        let base = home.arrange(active: [resident, newcomer], petSize: petSize, screens: [screen])
        home.place(resident, in: 0, active: [resident, newcomer], capacity: base.capacity)
        let original = home
        let preview = try #require(base.expansionCells(toward: edge).first)
        let drop = CGPoint(x: preview.midX, y: preview.midY)
        #expect(base.expansionEdge(at: drop, home: home, screens: [screen], moving: newcomer, active: [resident, newcomer]) == edge)
        #expect(home == original)
        #expect(base.expansionEdge(at: CGPoint(x: 0, y: 0), home: home, screens: [screen],
                                   moving: newcomer, active: [resident, newcomer]) == nil)
        #expect(base.expansionEdge(at: CGPoint(x: base.cell(0).midX, y: base.cell(0).midY),
                                   home: home, screens: [screen], moving: newcomer, active: [resident, newcomer]) == nil)
        #expect(base.expansionEdge(at: drop, home: home, screens: [base.frame],
                                   moving: newcomer, active: [resident, newcomer]) == nil)
        let expandedResult = home.expand(toward: edge, layout: base, screens: [screen])
        let expanded = try #require(expandedResult)
        let target = try #require(expanded.slot(at: drop))
        home.place(newcomer, in: target, active: [resident, newcomer], capacity: expanded.capacity)
        let after = home.arrange(active: [resident, newcomer], petSize: petSize, screens: [screen])
        #expect(after == expanded && home.slots[target] == newcomer)
        #expect(after.cell(target) == preview)
        #expect(after.cell(try #require(home.slot(for: resident, capacity: after.capacity))) == base.cell(0))
    }

    @Test(arguments: PetHomeEdge.allCases)
    func movingOnlyOuterResidentFartherOutDoesNotBuildAnEmptyCorridor(edge: PetHomeEdge) throws {
        var home = smartHome()
        let ids = (0..<4).map { _ in UUID() }
        let base = home.arrange(active: ids, petSize: petSize, screens: [screen])
        let result = home.expand(toward: edge, layout: base, screens: [screen])
        let expanded = try #require(result)
        let outerRooms = expanded.indices(on: edge)
        home.place(ids[0], in: outerRooms[0], active: Set(ids), capacity: expanded.capacity)
        let preview = try #require(expanded.expansionCells(toward: edge).first)
        let drop = CGPoint(x: preview.midX, y: preview.midY)
        let snapshot = home
        #expect(expanded.expansionEdge(at: drop, home: home, screens: [screen], moving: ids[0], active: Set(ids)) == nil)
        #expect(home == snapshot)
        home.leave(ids[0])
        #expect(home.arrange(active: ids, petSize: petSize, screens: [screen]) == base)
        #expect(home.outside.contains(ids[0]))

        home = snapshot
        home.place(ids[1], in: outerRooms[1], active: Set(ids), capacity: expanded.capacity)
        #expect(expanded.expansionEdge(at: drop, home: home, screens: [screen], moving: ids[0], active: Set(ids)) == edge)
        #expect(expanded.expansionEdge(at: drop, home: home, screens: [screen],
                                       moving: ids[0], active: Set(ids.filter { $0 != ids[1] })) == nil)
    }

    @Test func dragDefersAutomaticResizeUntilRelease() throws {
        var home = smartHome()
        let ids = (0..<5).map { _ in UUID() }
        let base = home.arrange(active: Array(ids.prefix(4)), petSize: petSize, screens: [screen])
        #expect(home.arrange(active: ids, petSize: petSize, screens: [screen], allowResizing: false) == base)
        let expanded = home.arrange(active: ids, petSize: petSize, screens: [screen])
        #expect(expanded.capacity > base.capacity)
        home.leave(ids[4])
        #expect(home.arrange(active: ids, petSize: petSize, screens: [screen], allowResizing: false) == expanded)
        #expect(home.arrange(active: ids, petSize: petSize, screens: [screen]) == base)
    }

    @Test func manualModeDoesNotGrowUntilExplicitlyInvited() {
        var home = smartHome()
        home.automaticallyAssign = false
        let ids = (0..<10).map { _ in UUID() }
        home.outside = Set(ids)
        let base = home.arrange(active: ids, petSize: petSize, screens: [screen])
        #expect(base.capacity == 4 && home.slots.allSatisfy { $0 == nil })
        let filled = home.arrange(active: ids, petSize: petSize, screens: [screen], moveAll: true)
        #expect(filled.capacity >= ids.count)
        #expect(Set(home.slots.compactMap { $0 }) == Set(ids))
        #expect(home.outside.isEmpty && !home.automaticallyAssign)
    }

    @Test func turningOffFreezesCurrentDimensionsAndManualSizeResetsExpansion() throws {
        var home = smartHome()
        let ids = (0..<4).map { _ in UUID() }, newcomer = UUID()
        let base = home.arrange(active: ids, petSize: petSize, screens: [screen])
        let widerResult = home.expand(toward: .left, layout: base, screens: [screen])
        let wider = try #require(widerResult)
        let tallerResult = home.expand(toward: .bottom, layout: wider, screens: [screen])
        let taller = try #require(tallerResult)
        home.place(newcomer, in: taller.capacity - 1, active: Set(ids + [newcomer]), capacity: taller.capacity)
        let rooms = home.slots
        home.setSmartResize(false)
        #expect(home.columns == 3 && home.rows == 3 && !home.smartResize)
        #expect(home.expansion == PetHomeExpansion())
        #expect(home.arrange(active: ids + [newcomer], petSize: petSize, screens: [screen]) == taller)
        #expect(home.slots == rooms)
        home.setSmartResize(true)
        let topResult = home.expand(toward: .top, layout: taller, screens: [screen])
        _ = try #require(topResult)
        home.setBaseSize(columns: 4, rows: 2)
        #expect(home.expansion == PetHomeExpansion())
        #expect(home.effectiveColumns == 4 && home.effectiveRows == 2 && home.smartResize)
    }

    @Test func expansionStopsAtEightByEightAndScreenRemovalKeepsEveryoneVisible() {
        var home = smartHome()
        let largeScreen = CGRect(x: 1600, y: 0, width: 4000, height: 3000)
        home.x = 2800
        home.y = 1000
        let ids = (0..<65).map { _ in UUID() }
        let full = home.arrange(active: ids, petSize: petSize, screens: [screen, largeScreen])
        #expect(full.columns == 8 && full.rows == 8)
        #expect(home.slots.compactMap { $0 }.count == 64)
        #expect(full.preferredExpansion(home: home, screens: [largeScreen]) == nil)
        let smallerScreen = CGRect(x: 0, y: 0, width: 800, height: 600)
        let relocated = home.arrange(active: ids, petSize: petSize, screens: [smallerScreen])
        #expect(smallerScreen.contains(relocated.frame))
        #expect(relocated.capacity == 64 && relocated.cellSize < full.cellSize)
        #expect((0..<relocated.capacity).allSatisfy { smallerScreen.contains(relocated.cell($0)) })
    }

    @Test func shrinkOnSmallScreenSettlesImmediatelyAndSurvivesRestart() throws {
        var home = smartHome()
        let ids = (0..<30).map { _ in UUID() }
        _ = home.arrange(active: ids, petSize: petSize, screens: [screen])
        let smallerScreen = CGRect(x: 0, y: 0, width: 400, height: 350)
        let fitted = home.arrange(active: ids, petSize: petSize, screens: [smallerScreen])
        let remaining = Array(ids.prefix(4))
        let shrunk = home.arrange(active: remaining, petSize: petSize, screens: [smallerScreen])
        #expect(shrunk.cellSize > fitted.cellSize)
        #expect(smallerScreen.contains(shrunk.frame))
        let saved = home
        home = try JSONDecoder().decode(PetHome.self, from: JSONEncoder().encode(home))
        #expect(home.arrange(active: remaining, petSize: petSize, screens: [smallerScreen]) == shrunk)
        #expect(home == saved)
    }

    private func smartHome() -> PetHome {
        var home = PetHome()
        home.enabled = true
        home.smartResize = true
        home.columns = 2
        home.rows = 2
        home.x = 500
        home.y = 300
        return home
    }
}
