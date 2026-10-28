import CoreGraphics
import Foundation

public enum PetPlacement {
    /// 滿房時保留自由位置；若原位被宿舍蓋住，選距離最近且放得下的外側區域。
    public static func outsideOrigin(for pet: CGRect, avoiding home: CGRect, screens: [CGRect]) -> CGPoint {
        let visible = visibleOrigin(for: pet, screens: screens)
        if !CGRect(origin: visible, size: pet.size).intersects(home) { return visible }
        let regions = screens.flatMap { screen -> [CGRect] in
            guard screen.intersects(home) else { return [screen] }
            let overlap = screen.intersection(home)
            return [CGRect(x: screen.minX, y: screen.minY, width: overlap.minX - screen.minX, height: screen.height),
                    CGRect(x: overlap.maxX, y: screen.minY, width: screen.maxX - overlap.maxX, height: screen.height),
                    CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: overlap.minY - screen.minY),
                    CGRect(x: screen.minX, y: overlap.maxY, width: screen.width, height: screen.maxY - overlap.maxY)]
        }.filter { $0.width >= pet.width && $0.height >= pet.height }
        return regions.map { visibleOrigin(for: pet, screens: [$0]) }.min {
            hypot($0.x - pet.minX, $0.y - pet.minY) < hypot($1.x - pet.minX, $1.y - pet.minY)
        } ?? visible
    }

    /// 保留可見位置；螢幕拔除或縮小時，移回距離最近的可用範圍。
    public static func visibleOrigin(for pet: CGRect, screens: [CGRect]) -> CGPoint {
        if screens.contains(where: { $0.contains(pet) }) { return pet.origin }
        return screens.map { screen in
            CGPoint(x: min(max(pet.minX, screen.minX), max(screen.minX, screen.maxX - pet.width)),
                    y: min(max(pet.minY, screen.minY), max(screen.minY, screen.maxY - pet.height)))
        }.min { left, right in
            hypot(left.x - pet.minX, left.y - pet.minY) < hypot(right.x - pet.minX, right.y - pet.minY)
        } ?? pet.origin
    }
}
