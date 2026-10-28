import CoreGraphics
import Foundation

public enum PetHomeEdge: String, CaseIterable, Codable, Sendable {
    case right, bottom, left, top

    var isColumn: Bool { self == .left || self == .right }
}

/// 相容舊版分開保存的加蓋格數；下次擴縮時會併入目前格數。
public struct PetHomeExpansion: Codable, Equatable, Sendable {
    public var left = 0
    public var right = 0
    public var top = 0
    public var bottom = 0

    public init() {}

    subscript(edge: PetHomeEdge) -> Int {
        get {
            switch edge {
            case .left: left
            case .right: right
            case .top: top
            case .bottom: bottom
            }
        }
        set {
            switch edge {
            case .left: left = newValue
            case .right: right = newValue
            case .top: top = newValue
            case .bottom: bottom = newValue
            }
        }
    }
}

extension PetHome {
    public mutating func setSmartResize(_ enabled: Bool) {
        if !enabled {
            columns = effectiveColumns
            rows = effectiveRows
            expansion = PetHomeExpansion()
        }
        smartResize = enabled
    }

    public mutating func setSize(columns: Int, rows: Int) {
        self.columns = min(max(columns, 1), 8)
        self.rows = min(max(rows, 1), 8)
        expansion = PetHomeExpansion()
    }

    public mutating func arrange(active: [UUID], petSize: CGFloat, screens: [CGRect],
                                 moveAll: Bool = false, constrain: Bool = true,
                                 allowResizing: Bool = true) -> PetHomeLayout {
        var layout = PetHomeLayout(home: self, petSize: petSize, screens: screens, constrain: constrain)
        x = layout.frame.minX
        y = layout.frame.minY
        reconcile(active: active, capacity: layout.capacity, moveAll: moveAll)
        guard enabled && smartResize && allowResizing else { return layout }

        if automaticallyAssign || moveAll {
            while active.contains(where: { !outside.contains($0) && slot(for: $0, capacity: layout.capacity) == nil }),
                  let edge = layout.preferredExpansion(home: self, screens: screens),
                  let expanded = expand(toward: edge, layout: layout, screens: screens) {
                layout = expanded
                reconcile(active: active, capacity: layout.capacity, moveAll: moveAll)
            }
        }
        let residents = Set(active)
        while let edge = PetHomeEdge.allCases.first(where: { edge in
            (edge.isColumn ? layout.columns : layout.rows) > 1 && layout.indices(on: edge).allSatisfy { index in
                slots[index].map { !residents.contains($0) } ?? true
            }
        }) {
            layout = resize(layout: layout, edge: edge, growing: false)
        }
        // 小螢幕上縮回後可能恢復原尺寸，同一輪就完成縮放與邊界校正。
        let settled = PetHomeLayout(home: self, petSize: petSize, screens: screens, constrain: constrain)
        x = settled.frame.minX
        y = settled.frame.minY
        return settled
    }

    /// 擴充和預覽共用幾何，舊房間的螢幕位置保持不變。
    @discardableResult
    public mutating func expand(toward edge: PetHomeEdge, layout: PetHomeLayout,
                                screens: [CGRect]) -> PetHomeLayout? {
        guard layout.canExpand(edge, home: self, screens: screens) else { return nil }
        return resize(layout: layout, edge: edge, growing: true)
    }

    private mutating func resize(layout: PetHomeLayout, edge: PetHomeEdge, growing: Bool) -> PetHomeLayout {
        let resized = layout.resized(toward: edge, growing: growing)
        let delta = growing ? 1 : -1
        let rowOffset = edge == .top ? delta : 0
        let columnOffset = edge == .left ? delta : 0
        var rooms = [UUID?](repeating: nil, count: resized.capacity)
        for (index, id) in slots.prefix(layout.capacity).enumerated() {
            let row = index / layout.columns + rowOffset
            let column = index % layout.columns + columnOffset
            if (0..<resized.rows).contains(row), (0..<resized.columns).contains(column) {
                rooms[row * resized.columns + column] = id
            }
        }
        slots = rooms
        columns = resized.columns
        rows = resized.rows
        expansion = PetHomeExpansion()
        x = resized.frame.minX
        y = resized.frame.minY
        return resized
    }
}

extension PetHomeLayout {
    func indices(on edge: PetHomeEdge) -> [Int] {
        switch edge {
        case .left: (0..<rows).map { $0 * columns }
        case .right: (0..<rows).map { $0 * columns + columns - 1 }
        case .top: Array(0..<columns)
        case .bottom: Array((rows - 1) * columns..<capacity)
        }
    }

    func resized(toward edge: PetHomeEdge, growing: Bool) -> PetHomeLayout {
        let delta = growing ? 1 : -1
        let step = CGFloat(delta) * (cellSize + Self.gap)
        var rect = frame
        if edge.isColumn { rect.size.width += step } else { rect.size.height += step }
        if edge == .left { rect.origin.x -= step }
        if edge == .bottom { rect.origin.y -= step }
        return PetHomeLayout(frame: rect, columns: columns + (edge.isColumn ? delta : 0),
                             rows: rows + (edge.isColumn ? 0 : delta), cellSize: cellSize)
    }

    public func expandedFrame(toward edge: PetHomeEdge) -> CGRect {
        resized(toward: edge, growing: true).frame
    }

    public func expansionCells(toward edge: PetHomeEdge) -> [CGRect] {
        let expanded = resized(toward: edge, growing: true)
        return expanded.indices(on: edge).map { expanded.cell($0) }
    }

    public func canExpand(_ edge: PetHomeEdge, home: PetHome, screens: [CGRect]) -> Bool {
        home.enabled && home.smartResize && (edge.isColumn ? columns : rows) < 8
            && screens.contains { $0.contains(expandedFrame(toward: edge)) }
    }

    public func preferredExpansion(home: PetHome, screens: [CGRect]) -> PetHomeEdge? {
        let available = PetHomeEdge.allCases.filter { canExpand($0, home: home, screens: screens) }
        return available.min { lhs, rhs in
            let a = resized(toward: lhs, growing: true), b = resized(toward: rhs, growing: true)
            let aShape = abs(log(Double(a.columns) / Double(a.rows) / 1.6))
            let bShape = abs(log(Double(b.columns) / Double(b.rows) / 1.6))
            if abs(aShape - bShape) > 0.001 { return aShape < bShape }
            return clearance(toward: lhs, screens: screens) > clearance(toward: rhs, screens: screens)
        }
    }

    public func expansionEdge(at point: CGPoint, home: PetHome, screens: [CGRect],
                              moving id: UUID, active: Set<UUID>) -> PetHomeEdge? {
        guard slot(at: point) == nil else { return nil }
        let source = home.slot(for: id, capacity: capacity)
        return PetHomeEdge.allCases.first { edge in
            guard canExpand(edge, home: home, screens: screens) else { return false }
            let edgeRooms = indices(on: edge)
            if let source, edgeRooms.contains(source) {
                let othersRemain = edgeRooms.contains { index in
                    guard home.slots.indices.contains(index), let resident = home.slots[index] else { return false }
                    return resident != id && active.contains(resident)
                }
                guard othersRemain else { return false }
            }
            return expansionCells(toward: edge).contains { $0.contains(point) }
        }
    }

    private func clearance(toward edge: PetHomeEdge, screens: [CGRect]) -> CGFloat {
        screens.filter { $0.contains(expandedFrame(toward: edge)) }.map { screen in
            switch edge {
            case .left: frame.minX - screen.minX
            case .right: screen.maxX - frame.maxX
            case .top: screen.maxY - frame.maxY
            case .bottom: frame.minY - screen.minY
            }
        }.max() ?? 0
    }
}
