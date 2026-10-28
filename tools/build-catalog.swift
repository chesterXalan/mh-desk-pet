import Foundation

struct Character: Decodable {
    let names: [String: String]
    let emID: Int
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let directory = root.appendingPathComponent("Resources/Characters")
let folders = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles])
    .filter { try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true }
let characters: [(folder: URL, metadata: Character)] = try folders.map { folder in
        (folder: folder, metadata: try JSONDecoder().decode(Character.self,
            from: Data(contentsOf: folder.appendingPathComponent("character.json"))))
    }
    .sorted {
        $0.metadata.emID == $1.metadata.emID
            ? $0.folder.lastPathComponent < $1.folder.lastPathComponent
            : $0.metadata.emID < $1.metadata.emID
    }
var document = """
# Monster roster

\(characters.count) companions, each with **idle**, **working**, and **waiting for input** animations.
Every animation uses four transparent 256 × 256 frames. Playback speed and display size are adjustable in the app.

Choose any monster in **Sessions**, or right-click a pet to change its character.
Thumbnails below link to the source frames; this roster is generated from the character metadata.
Monsters follow the same numeric **EM ID** order as the app. These are game resource IDs,
not encyclopedia numbers or popularity ranks; see [numbering sources](characters.md#monster-numbering).

| EM ID | Preview | English | 繁體中文 | 日本語 |
| --- | --- | --- | --- | --- |

"""
for (folder, metadata) in characters {
    let id = folder.lastPathComponent
    for state in ["idle", "working", "waiting"] {
        for frame in 0..<4 {
            guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(state)/\(frame).png").path) else {
                fatalError("Missing character frame: \(id)/\(state)/\(frame).png")
            }
        }
    }
    let english = metadata.names["en"] ?? id
    let chinese = metadata.names["zh-Hant"] ?? english
    let japanese = metadata.names["ja"] ?? english
    let link = "../Resources/Characters/\(id)"
    let code = String(format: "em%03d", metadata.emID)
    document += "| `\(code)` | <a href=\"\(link)\"><img src=\"\(link)/idle/0.png\" width=\"96\" height=\"96\" alt=\"\(english)\"></a> | \(english) | \(chinese) | \(japanese) |\n"
}
document += """

To add a companion, see [Character assets](characters.md), then run `make catalog` to refresh this list.
The [README preview](../README.md) shows a selection of the roster.

Monster Hunter characters belong to CAPCOM. These sprites are AI-generated fan art.

"""
try document.write(to: root.appendingPathComponent("docs/monsters.md"), atomically: true, encoding: .utf8)
print("Updated docs/monsters.md: \(characters.count) characters")
