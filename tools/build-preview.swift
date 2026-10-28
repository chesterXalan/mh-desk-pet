import AppKit
import ImageIO

struct Character: Decodable {
    let emID: Int
    let displayScale: Double
    let names: [String: String]
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let frames = root.appendingPathComponent(".build/readme-preview")
let output = root.appendingPathComponent("docs/assets/preview.gif")
let manager = FileManager.default
try manager.createDirectory(at: frames, withIntermediateDirectories: true)
try manager.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
}

func text(_ value: String, in rect: CGRect, size: CGFloat, color: NSColor) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    (value as NSString).draw(in: rect, withAttributes: [
        .font: NSFont.systemFont(ofSize: size, weight: .medium),
        .foregroundColor: color,
        .paragraphStyle: paragraph,
    ])
}

// Show different animation states without changing source frames or app settings.
let groups: [(state: String, label: String, color: NSColor, characters: [String])] = [
    ("working", "Working", color(0x86DCC4), ["zinogre", "mizutsune", "rathalos", "valstrax"]),
    ("waiting", "Waiting for input", color(0xE8BC78), ["velkhana", "tigrex"]),
    ("idle", "Idle", color(0xA4B9D3), ["nargacuga", "nergigante"]),
]
let metadata = try Dictionary(uniqueKeysWithValues: groups.flatMap(\.characters).map { id in
    let file = root.appendingPathComponent("Resources/Characters/\(id)/character.json")
    return (id, try JSONDecoder().decode(Character.self, from: Data(contentsOf: file)))
})
let orderedGroups = groups.map { group in
    (state: group.state, label: group.label, color: group.color,
     characters: group.characters.sorted { metadata[$0]!.emID < metadata[$1]!.emID })
}
let cell: CGFloat = 200
let margin: CGFloat = 36
let gap: CGFloat = 36
let width = Int(margin * 2 + cell * CGFloat(groups.reduce(0) { $0 + $1.characters.count })
                + gap * CGFloat(groups.count - 1))
let height = 340

for frame in 0..<4 {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(color(0x142129).cgColor)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)

    var groupX = margin
    var characterIndex = 0
    for group in orderedGroups {
        let groupWidth = cell * CGFloat(group.characters.count)
        text(group.label, in: CGRect(x: groupX, y: 293, width: groupWidth, height: 34),
             size: 26, color: group.color)
        context.setFillColor(group.color.withAlphaComponent(0.28).cgColor)
        context.fill(CGRect(x: groupX + 12, y: 279, width: groupWidth - 24, height: 2))

        for (index, id) in group.characters.enumerated() {
            let directory = root.appendingPathComponent("Resources/Characters/\(id)")
            let character = metadata[id]!
            // Stagger initial frames to avoid synchronized movement while keeping a 1.2-second loop for each monster.
            let source = directory.appendingPathComponent("\(group.state)/\((frame + characterIndex) % 4).png")
            guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
                  let sprite = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
                fatalError("Cannot read preview frame: \(source.path)")
            }
            let x = groupX + CGFloat(index) * cell
            let size = 196 * character.displayScale
            context.interpolationQuality = .high
            context.draw(sprite, in: CGRect(x: x + (cell - size) / 2, y: 64, width: size, height: size))
            text(character.names["en"] ?? id, in: CGRect(x: x, y: 21, width: cell, height: 32),
                 size: 24, color: color(0xDFE9EB))
            characterIndex += 1
        }
        groupX += groupWidth + gap
    }
    NSGraphicsContext.restoreGraphicsState()
    let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
    try bitmap.representation(using: .png, properties: [:])!
        .write(to: frames.appendingPathComponent("\(frame).png"))
}

let ffmpeg = Process()
ffmpeg.executableURL = URL(fileURLWithPath: "/usr/bin/env")
ffmpeg.arguments = [
    "ffmpeg", "-v", "error", "-y", "-framerate", "10/3", "-start_number", "0",
    "-i", frames.appendingPathComponent("%d.png").path, "-frames:v", "4",
    "-filter_complex", "split[a][b];[a]palettegen=reserve_transparent=0[p];[b][p]paletteuse=dither=bayer:bayer_scale=3",
    "-fps_mode", "passthrough", "-loop", "0", "-final_delay", "30", output.path,
]
try ffmpeg.run()
ffmpeg.waitUntilExit()
guard ffmpeg.terminationStatus == 0 else {
    fatalError("Preview build failed. Install FFmpeg with 'brew install ffmpeg' and retry.")
}
print("Built docs/assets/preview.gif: \(width) x \(height), 4 frames, 1.2s")
