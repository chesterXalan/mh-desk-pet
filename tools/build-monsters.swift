import Foundation
import ImageIO

enum BuildError: Error { case failure(String) }

func run(_ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw BuildError.failure("GIF build failed. Install FFmpeg with 'brew install ffmpeg' and retry.")
    }
}

let root = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    : URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let manager = FileManager.default
let sources = root.appendingPathComponent("Resources/Characters")
let output = root.appendingPathComponent(".build/Characters")
let characters = try manager.contentsOfDirectory(at: sources, includingPropertiesForKeys: [.isDirectoryKey],
                                                options: [.skipsHiddenFiles])
    .filter { try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
guard !characters.isEmpty else { throw BuildError.failure("No character frames found") }
if manager.fileExists(atPath: output.path) { try manager.removeItem(at: output) }
try manager.createDirectory(at: output, withIntermediateDirectories: true)

for character in characters {
    let destination = output.appendingPathComponent(character.lastPathComponent)
    try manager.createDirectory(at: destination, withIntermediateDirectories: true)
    let metadata = character.appendingPathComponent("character.json")
    if manager.fileExists(atPath: metadata.path) {
        try manager.copyItem(at: metadata, to: destination.appendingPathComponent("character.json"))
    }
    for state in ["idle", "working", "waiting"] {
        let frames = character.appendingPathComponent(state)
        let pngs = try manager.contentsOfDirectory(atPath: frames.path).filter { $0.hasSuffix(".png") }.sorted()
        guard pngs == ["0.png", "1.png", "2.png", "3.png"] else {
            throw BuildError.failure("Expected 0.png through 3.png in \(frames.path)")
        }
        for name in pngs {
            let url = frames.appendingPathComponent(name)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  image.width == 256, image.height == 256 else {
                throw BuildError.failure("Expected a 256 x 256 PNG: \(url.path)")
            }
        }
        let gifURL = destination.appendingPathComponent("\(state).gif")
        // Keep the default GIF loop at 1.6 seconds; app settings control the playback duration.
        try run(["ffmpeg", "-v", "error", "-y", "-framerate", "5/2", "-start_number", "0",
                 "-i", frames.appendingPathComponent("%d.png").path,
                 "-filter_complex", "split[a][b];[a]palettegen=reserve_transparent=1:stats_mode=full[p];[b][p]paletteuse=dither=none:alpha_threshold=128",
                 "-fps_mode", "passthrough", "-gifflags", "0", "-loop", "0", "-final_delay", "40", gifURL.path])
        guard let decoded = CGImageSourceCreateWithURL(gifURL as CFURL, nil),
              CGImageSourceGetCount(decoded) == 4 else {
            throw BuildError.failure("Expected four GIF frames: \(gifURL.path)")
        }
        for index in 0..<4 {
            let properties = CGImageSourceCopyPropertiesAtIndex(decoded, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double
            guard let delay, abs(delay - 0.4) < 0.001 else {
                throw BuildError.failure("Expected a 0.4-second GIF frame: \(gifURL.path)")
            }
        }
        print("Built \(character.lastPathComponent)/\(state).gif: 4 frames, 1.6s")
    }
}
