import CoreGraphics
import Foundation

/// 宿舍只記房間分配，自由擺放的位置仍由原本的目錄設定保存。
public struct PetHome: Codable, Equatable, Sendable {
    public var enabled = false
    public var showsGrid = true
    public var automaticallyAssign = true
    public var columns = 4
    public var rows = 2
    public var x: Double?
    public var y: Double?
    public var slots: [UUID?] = []
    public var outside: Set<UUID> = []

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        showsGrid = try container.decodeIfPresent(Bool.self, forKey: .showsGrid) ?? true
        automaticallyAssign = try container.decodeIfPresent(Bool.self, forKey: .automaticallyAssign) ?? true
        columns = try container.decodeIfPresent(Int.self, forKey: .columns) ?? 4
        rows = try container.decodeIfPresent(Int.self, forKey: .rows) ?? 2
        x = try container.decodeIfPresent(Double.self, forKey: .x)
        y = try container.decodeIfPresent(Double.self, forKey: .y)
        slots = try container.decodeIfPresent([UUID?].self, forKey: .slots) ?? []
        outside = try container.decodeIfPresent(Set<UUID>.self, forKey: .outside) ?? []
    }

    /// 舊房客先保留房間；已離線的房間可重用，手動搬出的魔物不會被吸回來。
    public mutating func reconcile(active: [UUID], capacity: Int, moveAll: Bool = false) {
        guard enabled else { return }
        slots = Array(slots.prefix(capacity))
        let activeSet = Set(active)
        if moveAll { outside.subtract(activeSet) }
        var seen = Set<UUID>()
        for index in slots.indices {
            if let id = slots[index], !seen.insert(id).inserted || outside.contains(id) { slots[index] = nil }
        }
        if slots.count < capacity { slots += Array(repeating: nil, count: capacity - slots.count) }
        guard automaticallyAssign || moveAll else { return }
        for id in active where !outside.contains(id) && slot(for: id, capacity: capacity) == nil {
            guard let index = slots.prefix(capacity).firstIndex(where: { $0.map { !activeSet.contains($0) } ?? true }) else { break }
            for old in slots.indices where slots[old] == id { slots[old] = nil }
            slots[index] = id
        }
    }

    public func slot(for id: UUID, capacity: Int) -> Int? {
        slots.prefix(capacity).firstIndex { $0 == id }
    }

    /// 從外面換入有人住的房間時，傳回被換出去的房客，交由視窗層放到起點。
    @discardableResult
    public mutating func place(_ id: UUID, in target: Int, active: Set<UUID>, capacity: Int) -> UUID? {
        guard slots.indices.contains(target), target < capacity else { return nil }
        let source = slot(for: id, capacity: capacity)
        guard source != target else { return nil }
        let displaced = slots[target].flatMap { active.contains($0) ? $0 : nil }
        for old in slots.indices where slots[old] == id { slots[old] = nil }
        if let source { slots[source] = displaced }
        slots[target] = id
        outside.remove(id)
        if source == nil, let displaced {
            outside.insert(displaced)
            return displaced
        }
        return nil
    }

    public mutating func leave(_ id: UUID) {
        for index in slots.indices where slots[index] == id { slots[index] = nil }
        outside.insert(id)
    }

}

/// 宿舍與每格的螢幕座標；顯示或隱藏背景不會改變吸附位置。
public struct PetHomeLayout: Equatable {
    public static let padding: CGFloat = 10
    public static let gap: CGFloat = 6
    public static let headerHeight: CGFloat = 32

    public let frame: CGRect
    public let columns: Int
    public let rows: Int
    public let cellSize: CGFloat
    public var capacity: Int { columns * rows }

    public init(home: PetHome, petSize: CGFloat, screens: [CGRect], constrain: Bool = true) {
        let screens = screens.isEmpty ? [CGRect(x: 0, y: 0, width: 1440, height: 900)] : screens
        let saved = home.x.flatMap { x in home.y.map { CGPoint(x: x, y: $0) } }
        let screen = saved.flatMap { point in
            screens.first { $0.contains(point) } ?? screens.min {
                Self.distance(point, to: $0) < Self.distance(point, to: $1)
            }
        } ?? screens[0]
        columns = min(max(home.columns, 1), 8)
        rows = min(max(home.rows, 1), 8)
        let availableWidth = (screen.width - 2 * Self.padding - CGFloat(columns - 1) * Self.gap) / CGFloat(columns)
        let availableHeight = (screen.height - Self.headerHeight - 2 * Self.padding
                               - CGFloat(rows - 1) * Self.gap) / CGFloat(rows)
        cellSize = max(20, min(ceil(petSize) + 12, min(availableWidth, availableHeight)))
        let step = cellSize + Self.gap
        let size = CGSize(width: CGFloat(columns) * step - Self.gap + 2 * Self.padding,
                          height: CGFloat(rows) * step - Self.gap + 2 * Self.padding + Self.headerHeight)
        let origin = saved ?? CGPoint(x: screen.maxX - size.width - 24, y: screen.minY + 24)
        let proposed = CGRect(origin: origin, size: size)
        frame = CGRect(origin: constrain ? PetPlacement.visibleOrigin(for: proposed, screens: [screen]) : origin,
                       size: size)
    }

    public func cell(_ index: Int) -> CGRect {
        let step = cellSize + Self.gap
        return CGRect(x: frame.minX + Self.padding + CGFloat(index % columns) * step,
                      y: frame.maxY - Self.headerHeight - Self.padding - cellSize - CGFloat(index / columns) * step,
                      width: cellSize, height: cellSize)
    }

    public func origin(for index: Int, petSize: CGFloat) -> CGPoint {
        let rect = cell(index)
        return CGPoint(x: rect.midX - petSize / 2, y: rect.midY - petSize / 2)
    }

    public func slot(at point: CGPoint) -> Int? {
        (0..<capacity).first { cell($0).insetBy(dx: -Self.gap / 2, dy: -Self.gap / 2).contains(point) }
    }

    private static func distance(_ point: CGPoint, to rect: CGRect) -> CGFloat {
        hypot(max(rect.minX - point.x, 0, point.x - rect.maxX),
              max(rect.minY - point.y, 0, point.y - rect.maxY))
    }
}
