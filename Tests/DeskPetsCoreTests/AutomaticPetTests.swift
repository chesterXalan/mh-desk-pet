import Foundation
import Testing
@testable import DeskPetsCore

@Suite struct AutomaticPetTests {
    private let characters = ["zinogre", "mizutsune", "nargacuga"]

    @Test func newDirectoryGetsOneStableRandomChoice() {
        var config = AppConfig()
        let session = AgentSession(provider: .codex, pid: 1, startTime: 100, cwd: "/project")
        var choices = 0
        let choose: ([String]) -> String? = { candidates in
            choices += 1
            return candidates.last
        }
        _ = BindingResolver.resolve(&config, sessions: [session], characters: characters, choose: choose)
        let first = config
        _ = BindingResolver.resolve(&config, sessions: [session], characters: characters, choose: choose)
        #expect(choices == 1)
        #expect(config == first)
        #expect(config.directoryPets[session.cwd]?.character == "nargacuga")
    }

    @Test func lastManualChoiceSurvivesClosingAndChangingProvider() throws {
        var config = AppConfig()
        let sessions = [AgentSession(provider: .claude, pid: 1, startTime: 100, cwd: "/project"),
                        AgentSession(provider: .codex, pid: 2, startTime: 200, cwd: "/project")]
        _ = BindingResolver.resolve(&config, sessions: sessions, characters: characters, choose: { $0.first })
        #expect(config.bindings.map(\.character) == ["zinogre", "mizutsune"])
        #expect(config.directoryPets["/project"]?.character == "zinogre")
        config.bindings[1].character = "nargacuga"
        config.bindings[1].x = 50
        config.rememberCharacter(from: config.bindings[1])
        _ = BindingResolver.resolve(&config, sessions: [], characters: characters)
        #expect(config.bindings.isEmpty)
        config = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config))
        let restarted = AgentSession(provider: .codex, pid: 3, startTime: 300, cwd: "/project")
        _ = BindingResolver.resolve(&config, sessions: [restarted], characters: characters, choose: { _ in nil })
        #expect(config.bindings.first?.character == "nargacuga")
        #expect(config.bindings.first?.x == 50)
    }

    @Test func randomExtrasAvoidDuplicatesUntilCharactersRunOut() {
        var config = AppConfig(directoryPets: ["/project": DirectoryPetPreference(character: "mizutsune")])
        let sessions = (1...5).map { AgentSession(provider: .codex, pid: Int32($0), startTime: Double($0), cwd: "/project") }
        _ = BindingResolver.resolve(&config, sessions: sessions, characters: characters, choose: { $0.first })
        #expect(config.bindings.count == sessions.count)
        #expect(config.bindings.first?.character == "mizutsune")
        #expect(Set(config.bindings.prefix(3).map(\.character)).count == 3)
        #expect(config.directoryPets["/project"]?.character == "mizutsune")
    }

    @Test func everyPositionSurvivesClosingAndReloading() throws {
        let bindings = positionedBindings()
        var config = AppConfig(bindings: bindings)
        config.rememberCharacter(from: bindings[0])
        _ = BindingResolver.resolve(&config, sessions: [], characters: characters)
        #expect(config.bindings.isEmpty)
        config = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config))

        let restarted = (1...3).map { (index: Int) -> AgentSession in
            let provider: Provider = index == 2 ? .claude : .codex
            return AgentSession(provider: provider, pid: Int32(index + 10),
                                startTime: Double(index + 10), cwd: "/project")
        }
        _ = BindingResolver.resolve(&config, sessions: restarted, characters: characters, choose: { $0.first })
        #expect(config.bindings.map(\.x) == bindings.map(\.x))
        #expect(config.bindings.map(\.y) == bindings.map(\.y))
        #expect(config.bindings.map(\.character) == characters)
    }

    @Test(arguments: [0, 1])
    func replacementReusesVacantPositionWithoutMovingLivePets(closed: Int) throws {
        let bindings = positionedBindings()
        var config = AppConfig(bindings: bindings)
        config.rememberCharacter(from: bindings[0])
        let remaining = bindings.enumerated().filter { $0.offset != closed }.map { _, binding in
            AgentSession(provider: binding.provider, pid: binding.pid!, startTime: binding.pidStart!, cwd: binding.cwd)
        }
        _ = BindingResolver.resolve(&config, sessions: remaining, characters: characters)
        config = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config))
        let replacement = AgentSession(provider: .codex, pid: 10, startTime: 10, cwd: "/project")
        _ = BindingResolver.resolve(&config, sessions: remaining + [replacement], characters: characters,
                                    choose: { $0.first })
        #expect(config.bindings.last?.x == bindings[closed].x)
        #expect(config.bindings.last?.y == bindings[closed].y)
        #expect(Array(config.bindings.dropLast()) == bindings.enumerated()
            .filter { $0.offset != closed }.map(\.element))
    }

    private func positionedBindings() -> [PetBinding] {
        characters.enumerated().map { index, character in
            PetBinding(provider: .claude, cwd: "/project", character: character,
                       pid: Int32(index + 1), pidStart: Double(index + 1),
                       x: Double(-500 + index * 150), y: Double(900 + index * 100))
        }
    }

    @Test func draggingExtraPetPersistsWithoutChangingPreferredCharacter() throws {
        let bindings = positionedBindings()
        var config = AppConfig(bindings: bindings)
        config.rememberCharacter(from: bindings[0])
        _ = BindingResolver.resolve(&config, sessions: bindings.map {
            AgentSession(provider: $0.provider, pid: $0.pid!, startTime: $0.pidStart!, cwd: $0.cwd)
        }, characters: characters)
        config.setPosition(bindings[1].id, x: -200, y: 1200)
        #expect(config.directoryPets["/project"]?.character == characters[0])

        for generation in 1...3 {
            _ = BindingResolver.resolve(&config, sessions: [], characters: characters)
            config = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config))
            let sessions = (0..<3).map { (index: Int) -> AgentSession in
                let pid = Int32(generation * 10 + index)
                return AgentSession(provider: .codex, pid: pid, startTime: Double(pid), cwd: "/project")
            }
            _ = BindingResolver.resolve(&config, sessions: sessions, characters: characters, choose: { $0.last })
            #expect(config.bindings[1].x == -200 && config.bindings[1].y == 1200)
            #expect(config.bindings.map(\.id) == bindings.map(\.id))
            #expect(config.directoryPositions["/project"]?.count == 3)
        }
    }

    @Test func legacyDirectoryPositionsStaySeparateAcrossProviders() throws {
        let data = Data(#"{"directoryPets":{"/first":{"character":"zinogre","x":100,"y":200},"/second":{"character":"zinogre","x":800,"y":600}}}"#.utf8)
        var config = try JSONDecoder().decode(AppConfig.self, from: data)
        let sessions = [AgentSession(provider: .claude, pid: 1, startTime: 1, cwd: "/first"),
                        AgentSession(provider: .codex, pid: 2, startTime: 2, cwd: "/second")]
        _ = BindingResolver.resolve(&config, sessions: sessions, characters: characters)
        #expect(config.bindings.map(\.x) == [100, 800])
        #expect(config.bindings.map(\.y) == [200, 600])
        #expect(config.directoryPositions.count == 2)
        let restored = config
        _ = BindingResolver.resolve(&config, sessions: sessions, characters: characters)
        #expect(config == restored)
    }

    @Test func randomChoicesAvoidPetsInOtherDirectories() {
        let active = PetBinding(provider: .claude, cwd: "/first", character: "zinogre", pid: 1, pidStart: 100, x: 12, y: 34)
        var config = AppConfig(bindings: [active])
        let sessions = [AgentSession(provider: .claude, pid: 1, startTime: 100, cwd: "/first"),
                        AgentSession(provider: .codex, pid: 2, startTime: 200, cwd: "/second")]
        _ = BindingResolver.resolve(&config, sessions: sessions, characters: characters, choose: { $0.first })
        #expect(config.bindings[0] == active)
        #expect(config.bindings[1].character == "mizutsune")
    }

    @Test func hiddenSessionStaysHiddenWithoutForgettingDirectoryChoice() throws {
        var config = AppConfig(directoryPets: ["/project": DirectoryPetPreference(character: "zinogre")])
        let session = AgentSession(provider: .codex, pid: 1, startTime: 100, cwd: "/project")
        _ = BindingResolver.resolve(&config, sessions: [session], characters: characters)
        config.bindings[0].character = ""
        config = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config))
        _ = BindingResolver.resolve(&config, sessions: [session], characters: characters)
        #expect(config.bindings[0].character.isEmpty)
        #expect(config.directoryPets["/project"]?.character == "zinogre")
        let restarted = AgentSession(provider: .codex, pid: 2, startTime: 200, cwd: "/project")
        _ = BindingResolver.resolve(&config, sessions: [restarted], characters: characters)
        #expect(config.bindings.count == 1 && config.bindings[0].character == "zinogre")
    }

    @Test func removedCharacterGetsReplacedAndEmptyLibraryIsSafe() {
        var config = AppConfig(bindings: [PetBinding(provider: .codex, cwd: "/project", character: "removed",
                                                    pid: 1, pidStart: 100, x: 50, y: 60)],
                               directoryPets: ["/project": DirectoryPetPreference(character: "removed")])
        let session = AgentSession(provider: .codex, pid: 1, startTime: 100, cwd: "/project")
        _ = BindingResolver.resolve(&config, sessions: [session], characters: characters, choose: { $0.first })
        #expect(config.bindings[0].character == "zinogre" && config.bindings[0].x == 50)
        #expect(config.directoryPets["/project"]?.character == "zinogre")
        _ = BindingResolver.resolve(&config, sessions: [session], characters: [])
        #expect(config.bindings.isEmpty)
    }
}
