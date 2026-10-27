import Foundation

struct Character: Decodable {
    let names: [String: String]
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let directory = root.appendingPathComponent("Resources/Characters")
let folders = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles])
    .filter { try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
var document = """
# Monster roster

\(folders.count) companions, each with **idle**, **working**, and **waiting for input** animations.
Every animation uses four transparent 256 × 256 frames. Playback speed and display size are adjustable in the app.

Choose any monster in **Sessions**, or right-click a pet to change its character.
Thumbnails below link to the source frames; this roster is generated from the character metadata.

| Preview | English | 繁體中文 | 日本語 |
| --- | --- | --- | --- |

"""
for folder in folders {
    let id = folder.lastPathComponent
    let metadata = try JSONDecoder().decode(Character.self,
        from: Data(contentsOf: folder.appendingPathComponent("character.json")))
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
    document += "| <a href=\"\(link)\"><img src=\"\(link)/idle/0.png\" width=\"96\" height=\"96\" alt=\"\(english)\"></a> | \(english) | \(chinese) | \(japanese) |\n"
}
document += """

To add a companion, see [Character assets](characters.md), then run `make catalog` to refresh this list.
The [README preview](../README.md) shows a selection of the roster.

Monster Hunter characters belong to CAPCOM. These sprites are AI-generated fan art.

"""
try document.write(to: root.appendingPathComponent("docs/monsters.md"), atomically: true, encoding: .utf8)
print("Updated docs/monsters.md: \(folders.count) characters")
