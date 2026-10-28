import Foundation
import Testing
@testable import DeskPetsCore

@Suite struct LocalizationTests {
    private var resources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources")
    }

    @Test func resolvesSystemLanguagesAndOverrides() {
        #expect(AppLanguage.system.resolved(preferredLanguages: ["zh-TW"]) == .traditionalChinese)
        #expect(AppLanguage.system.resolved(preferredLanguages: ["zh_HK"]) == .traditionalChinese)
        #expect(AppLanguage.system.resolved(preferredLanguages: ["ja-JP", "en"]) == .japanese)
        #expect(AppLanguage.system.resolved(preferredLanguages: ["fr-FR", "ja"]) == .english)
        #expect(AppLanguage.system.resolved(preferredLanguages: ["zh-Hant-TW", "en"]) == .traditionalChinese)
        #expect(AppLanguage.system.resolved(preferredLanguages: ["zh-Hans-CN", "zh-Hant"]) == .english)
        #expect(AppLanguage.system.resolved(preferredLanguages: ["zh-CN"]) == .english)
        #expect(AppLanguage.system.resolved(preferredLanguages: ["en-GB", "ja"]) == .english)
        #expect(AppLanguage.system.resolved(preferredLanguages: ["de"]) == .english)
        #expect(AppLanguage.system.resolved(preferredLanguages: []) == .english)
        #expect(AppLanguage.japanese.resolved(preferredLanguages: ["zh-TW"]) == .japanese)
        #expect(AppConfig().language == .system)
    }

    @Test func translationsHaveMatchingKeysAndFormats() throws {
        let localization = AppLocalization(resourceURL: resources)
        let formats = try NSRegularExpression(pattern: "%[0-9.]*[@df]")
        var reference: [String: String] = [:]
        for language in [AppLanguage.english, .traditionalChinese, .japanese] {
            let data = try Data(contentsOf: resources.appendingPathComponent("\(language.rawValue).lproj/Localizable.strings"))
            let strings = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
            if language == .english { reference = strings }
            #expect(Set(strings.keys) == Set(reference.keys))
            for (key, text) in strings {
                #expect(!text.isEmpty)
                #expect(localization.text(key, language: language) == text)
                let placeholders = { (value: String) in
                    formats.matches(in: value, range: NSRange(value.startIndex..., in: value))
                        .map { (value as NSString).substring(with: $0.range) }
                }
                #expect(placeholders(text) == placeholders(reference[key] ?? ""))
            }
        }
        #expect(localization.text("language.label", language: .japanese) == "言語")
        #expect(localization.text("missing.key", language: .japanese) == "missing.key")
    }

    @Test func languageRoundTripsWithoutChangingBindings() throws {
        let binding = PetBinding(provider: .codex, cwd: "/project", character: "zinogre", x: 12, y: 34)
        let config = AppConfig(petSize: 128, bindings: [binding], animationDuration: 1.2, language: .japanese)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config))
        #expect(decoded == config)
    }

    @Test func bundledMonstersHaveUniqueEMIDsAndAnUpToDateRoster() throws {
        struct Metadata: Decodable { let emID: Int }
        let folders = try FileManager.default.contentsOfDirectory(at: resources.appendingPathComponent("Characters"),
                                                                  includingPropertiesForKeys: nil)
        let characters = try folders.map { folder in
            (name: folder.lastPathComponent, metadata: try JSONDecoder().decode(Metadata.self,
                from: Data(contentsOf: folder.appendingPathComponent("character.json"))))
        }.sorted { $0.metadata.emID < $1.metadata.emID }
        let ids = characters.map { $0.metadata.emID }
        #expect(ids.allSatisfy { $0 > 0 })
        #expect(Set(ids).count == ids.count)
        let rosterURL = resources.deletingLastPathComponent().appendingPathComponent("docs/monsters.md")
        let rows = try String(contentsOf: rosterURL, encoding: .utf8).components(separatedBy: "\n")
            .filter { $0.hasPrefix("| `em") }
        #expect(rows.count == characters.count)
        for (row, character) in zip(rows, characters) {
            #expect(row.hasPrefix("| `\(String(format: "em%03d", character.metadata.emID))` |"))
            #expect(row.contains("../Resources/Characters/\(character.name)\""))
        }
    }

    @Test(arguments: ["null", "42", "\"unknown\""])
    func invalidLanguageKeepsOtherSettings(value: String) throws {
        let data = Data("{\"language\":\(value),\"petSize\":128,\"animationDuration\":1.2}".utf8)
        let config = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(config.language == .system)
        #expect(config.petSize == 128 && config.animationDuration == 1.2)
    }

    @Test func migratesLegacyCharactersWithoutDuplicatesOrLostSettings() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? manager.removeItem(at: root) }
        let builtin = root.appendingPathComponent("builtin")
        let custom = root.appendingPathComponent("custom")
        let source = resources.appendingPathComponent("Characters")
        let folders = try manager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil).sorted { $0.path < $1.path }
        var before: [PetBinding] = []
        var after: [PetBinding] = []
        for (index, folder) in folders.enumerated() {
            let data = try Data(contentsOf: folder.appendingPathComponent("character.json"))
            let metadata = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let aliases = metadata["aliases"] as? [String] ?? []
            let legacy = aliases.first ?? folder.lastPathComponent
            for directory in [builtin.appendingPathComponent(folder.lastPathComponent), custom.appendingPathComponent(legacy)] {
                try manager.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data("GIF89a-fake".utf8).write(to: directory.appendingPathComponent("idle.gif"))
            }
            try data.write(to: builtin.appendingPathComponent("\(folder.lastPathComponent)/character.json"))
            var binding = PetBinding(provider: .codex, cwd: "/project/\(index)", character: legacy,
                                     pid: Int32(index + 100), pidStart: 123, x: Double(index * 100), y: 20)
            before.append(binding)
            binding.character = folder.lastPathComponent
            after.append(binding)
        }
        let mochi = custom.appendingPathComponent("Mochi")
        try manager.createDirectory(at: mochi, withIntermediateDirectories: true)
        try Data("GIF89a-fake".utf8).write(to: mochi.appendingPathComponent("idle.gif"))
        for name in ["Mochi", "missing", "zinogre"] {
            let binding = PetBinding(provider: .claude, cwd: "/custom", character: name)
            before.append(binding)
            after.append(binding)
        }
        let library = CharacterLibrary(builtInRoot: builtin, customRoot: custom)
        let characters = library.list()
        #expect(characters.count == folders.count + 1)
        #expect(characters.filter { !$0.builtIn }.map(\.name) == ["Mochi"])
        let original = AppConfig(petSize: 128, bindings: before, animationDuration: 1.2)
        var migrated = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(original))
        let changed = migrated.migrateCharacterNames(using: characters)
        #expect(changed)
        #expect(migrated == AppConfig(petSize: 128, bindings: after, animationDuration: 1.2))
        let changedAgain = migrated.migrateCharacterNames(using: characters)
        #expect(!changedAgain)
        let zinogre = try #require(library.character(named: "雷狼龍"))
        #expect(zinogre.name == "zinogre")
        #expect(zinogre.displayName(in: .english) == "Zinogre")
        #expect(zinogre.displayName(in: .traditionalChinese) == "雷狼龍")
        #expect(zinogre.displayName(in: .japanese) == "ジンオウガ")
        #expect(library.character(named: "Mochi")?.displayName(in: .japanese) == "Mochi")
        let untranslated = CharacterInfo(name: "custom", directory: custom, builtIn: false, names: ["en": "Custom"])
        #expect(untranslated.displayName(in: .japanese) == "Custom")
    }
}
