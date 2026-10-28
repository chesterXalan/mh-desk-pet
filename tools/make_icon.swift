// Generate macOS icon sizes from the versioned source artwork.
// Usage: swift tools/make_icon.swift.
import AppKit
import ImageIO

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let artwork = root.appendingPathComponent("Resources/Branding/AppIcon.png")
guard let source = CGImageSourceCreateWithURL(artwork as CFURL, nil),
      let icon = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fatalError("cannot read \(artwork.path)")
}

func render(size: Int) -> Data {
    let s = CGFloat(size)
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Preserve transparent edges and leave padding around the macOS icon.
    let scale = s * 0.84 / CGFloat(max(icon.width, icon.height))
    let width = CGFloat(icon.width) * scale, height = CGFloat(icon.height) * scale
    ctx.interpolationQuality = .high
    ctx.draw(icon, in: CGRect(x: (s - width) / 2, y: (s - height) / 2, width: width, height: height))
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

let iconset = root.appendingPathComponent(".build/AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let out = root.appendingPathComponent("Resources/AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("wrote \(out.path)")
