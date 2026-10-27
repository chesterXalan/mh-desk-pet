import AppKit
import ImageIO

// 將已檢查的 4 × 3 透明圖集切成影格，統一縮放比例與站立基準。
guard CommandLine.arguments.count == 3 else {
    fatalError("Usage: swift tools/import-sprite-sheet.swift SHEET.png OUTPUT_DIRECTORY")
}
let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let sheet = CGImageSourceCreateImageAtIndex(source, 0, nil),
      sheet.width >= 4, sheet.height >= 3 else {
    fatalError("Cannot read sprite sheet")
}

func geometry(of image: CGImage) -> (bounds: CGRect, anchor: CGFloat) {
    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    return pixels.withUnsafeMutableBytes { buffer in
        let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where buffer[(y * width + x) * 4 + 3] >= 16 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { fatalError("Empty sprite cell") }
        guard minX > 0, minY > 0, maxX < width - 1, maxY < height - 1 else {
            fatalError("Sprite touches a cell boundary; repair its transparent gutters before importing")
        }
        // 用底部腳掌範圍對齊，避免特效擴張或轉頭時整隻寵物左右跳動。
        var footMinX = width, footMaxX = -1
        for y in (maxY - (maxY - minY) / 8)...maxY {
            for x in minX...maxX where buffer[(y * width + x) * 4 + 3] >= 128 {
                footMinX = min(footMinX, x); footMaxX = max(footMaxX, x)
            }
        }
        let anchor = footMaxX >= footMinX ? CGFloat(footMinX + footMaxX) / 2 : CGFloat(minX + maxX) / 2
        return (CGRect(x: minX, y: height - maxY - 1, width: maxX - minX + 1, height: maxY - minY + 1), anchor)
    }
}

var sprites: [(image: CGImage, bounds: CGRect, anchor: CGFloat)] = []
for row in 0..<3 {
    for column in 0..<4 {
        let x = column * sheet.width / 4, y = row * sheet.height / 3
        let rect = CGRect(x: x, y: y, width: (column + 1) * sheet.width / 4 - x,
                          height: (row + 1) * sheet.height / 3 - y)
        let image = sheet.cropping(to: rect)!
        let placement = geometry(of: image)
        sprites.append((image, placement.bounds, placement.anchor))
    }
}
let union = sprites.reduce(CGRect.null) { $0.union($1.bounds.offsetBy(dx: -$1.anchor, dy: 0)) }
let idleHeight = sprites.prefix(4).map { $0.bounds.height }.sorted()[2]
let maxHeight = sprites.map { $0.bounds.height }.max()!
let scale = min(218 / idleHeight, 230 / union.width, 230 / maxHeight)
let manager = FileManager.default
for (row, state) in ["idle", "working", "waiting"].enumerated() {
    let directory = output.appendingPathComponent(state)
    guard !manager.fileExists(atPath: directory.path) else {
        fatalError("Output already exists: \(directory.path)")
    }
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    for frame in 0..<4 {
        let sprite = sprites[row * 4 + frame]
        let context = CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.interpolationQuality = .high
        context.draw(sprite.image, in: CGRect(x: 128 - (union.midX + sprite.anchor) * scale,
                                             y: 16 - sprite.bounds.minY * scale,
                                             width: CGFloat(sprite.image.width) * scale,
                                             height: CGFloat(sprite.image.height) * scale))
        let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
        try bitmap.representation(using: .png, properties: [:])!
            .write(to: directory.appendingPathComponent("\(frame).png"))
    }
}
print("Imported \(output.lastPathComponent): 12 transparent 256 x 256 frames, shared scale \(scale)")
