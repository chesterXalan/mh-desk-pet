import Foundation

/// The Codex title index provides IDs, names, and timestamps without reading conversation content.
enum CodexSessionIndex {
    static func titles(in data: Data) -> [String: String] {
        var titles: [String: String] = [:]
        for line in data.split(separator: 0x0a) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let rawID = object["id"] as? String, let id = UUID(uuidString: rawID),
                  let name = object["thread_name"] as? String else { continue }
            let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
            titles[id.uuidString.lowercased()] = cleaned.isEmpty ? nil : String(cleaned.prefix(120))
        }
        return titles
    }
}
