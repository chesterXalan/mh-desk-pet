import Foundation
import Testing
@testable import DeskPetsCore

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("deskpets-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite struct HookEventTests {
    @Test func mapsEventsToStates() {
        #expect(HookEvents.state(for: ["hook_event_name": "UserPromptSubmit"]) == .working)
        #expect(HookEvents.state(for: ["hook_event_name": "PreToolUse"]) == .working)
        #expect(HookEvents.state(for: ["hook_event_name": "Notification", "notification_type": "permission_prompt"]) == .waiting)
        #expect(HookEvents.state(for: ["hook_event_name": "Notification", "notification_type": "idle_prompt"]) == .waiting)
        #expect(HookEvents.state(for: ["hook_event_name": "PermissionRequest"]) == .waiting)
        #expect(HookEvents.state(for: ["hook_event_name": "Stop"]) == .idle)
        #expect(HookEvents.state(for: ["hook_event_name": "SessionStart", "source": "startup"]) == .idle)
        #expect(HookEvents.state(for: ["hook_event_name": "SessionEnd"]) == .exited)
        #expect(HookEvents.state(for: ["hook_event_name": "SomethingNew"]) == nil)
        #expect(HookEvents.state(for: [:]) == nil)
    }

    @Test func buildsRecordWithoutConversationContent() throws {
        let payload: [String: Any] = ["hook_event_name": "UserPromptSubmit", "session_id": "abc-123", "cwd": "/tmp/project",
                                      "prompt": "secret prompt text"]
        let record = try #require(HookEvents.record(provider: .claude, payload: payload, agent: (pid: 42, start: 1000),
                                                    now: Date(timeIntervalSince1970: 5)))
        #expect(record.state == .working)
        #expect(record.pid == 42)
        #expect(record.cwd == "/tmp/project")
        let encoded = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
        #expect(!encoded.contains("secret"))
    }

    @Test func ignoresSubagentsAndUnknownEvents() {
        #expect(HookEvents.record(provider: .claude, payload: ["hook_event_name": "Stop", "session_id": "a", "agent_id": "x"], agent: nil) == nil)
        #expect(HookEvents.record(provider: .claude, payload: ["hook_event_name": "SubagentStop", "session_id": "a"], agent: nil) == nil)
        #expect(HookEvents.record(provider: .claude, payload: ["hook_event_name": "Mystery", "session_id": "a"], agent: nil) == nil)
        #expect(HookEvents.record(provider: .claude, payload: ["hook_event_name": "Stop"], agent: nil) == nil)
    }

    @Test func writesAndReadsRecordsBySessionId() throws {
        let directory = try temporaryDirectory()
        let record = HookRecord(provider: .codex, sessionId: "s-1", state: .waiting, event: "PermissionRequest",
                                cwd: "/x", pid: 7, pidStart: 1, updatedAt: 2)
        let url = try HookEvents.write(record, to: directory)
        #expect(url.lastPathComponent == "s-1.json")
        #expect(HookEvents.readAll(from: directory) == [record])
        let unsafe = HookRecord(provider: .claude, sessionId: "../evil", state: .idle, event: "Stop", cwd: "", pid: 9, pidStart: 0, updatedAt: 0)
        #expect(HookEvents.fileName(for: unsafe) == "claude-pid-9.json")
    }
}

@Suite struct StateMergeTests {
    @Test func resumedCodexMatchesBackendBySessionId() throws {
        let id = "ba41fa31-c0a7-42d7-b5d1-59516579b291"
        let session = AgentSession(provider: .codex, pid: 20, startTime: 100, cwd: "/a", launchSessionId: id)
        let records = [
            HookRecord(provider: .codex, sessionId: id, state: .working, event: "PreToolUse", cwd: "/a",
                       pid: 10, pidStart: 50, title: "Resumed session", updatedAt: 101),
            HookRecord(provider: .codex, sessionId: "another-session", state: .waiting, event: "PermissionRequest",
                       cwd: "/a", pid: 10, pidStart: 50, updatedAt: 102),
            HookRecord(provider: .claude, sessionId: id, state: .idle, event: "Stop", cwd: "/a",
                       pid: 30, pidStart: 90, updatedAt: 103),
        ]
        let merged = try #require(SessionMerger.merge([session], records: records).first)
        #expect(merged.state == .working)
        #expect(merged.sessionId == id)
        #expect(merged.title == "Resumed session")
        #expect(merged.pid == session.pid)
        let names = SessionNamer(home: try temporaryDirectory()).names(for: [session], records: records)
        #expect(names[session.id] == "Resumed session")
    }

    @Test func resumedCodexRejectsStaleAndOtherProviderRecords() {
        let id = "ba41fa31-c0a7-42d7-b5d1-59516579b291"
        let session = AgentSession(provider: .codex, pid: 20, startTime: 100, cwd: "/a", launchSessionId: id)
        var record = HookRecord(provider: .codex, sessionId: id, state: .working, event: "PreToolUse",
                                cwd: "/a", pid: 10, pidStart: 50, updatedAt: 99)
        #expect(SessionMerger.merge([session], records: [record])[0].state == .unknown)
        record.updatedAt = 101
        var claude = session
        claude.provider = .claude
        record.provider = .claude
        #expect(SessionMerger.merge([claude], records: [record])[0].state == .unknown)
    }

    @Test func plainCodexMatchesUniqueRecentBackendRecordAndTitle() throws {
        let session = AgentSession(provider: .codex, pid: 20, startTime: 100, cwd: "/a")
        let claude = AgentSession(provider: .claude, pid: 30, startTime: 100, cwd: "/a")
        var record = HookRecord(provider: .codex, sessionId: "current", state: .working, event: "PreToolUse",
                                cwd: "/a", pid: 10, pidStart: 50, title: "Current conversation", updatedAt: 101)
        let old = HookRecord(provider: .codex, sessionId: "old", state: .idle, event: "Stop", cwd: "/a",
                             pid: 10, pidStart: 50, updatedAt: 99)
        let elsewhere = HookRecord(provider: .codex, sessionId: "elsewhere", state: .working, event: "PreToolUse",
                                   cwd: "/b", pid: 10, pidStart: 50, updatedAt: 102)
        let sessions = [session, claude]
        for state in [PetState.working, .waiting, .idle] {
            record.state = state
            let records = [old, elsewhere, record]
            let merged = SessionMerger.merge(sessions, records: records)
            #expect(merged[0].state == state)
            #expect(merged[0].sessionId == "current")
            #expect(merged[0].pid == session.pid)
            #expect(merged[1].state == .unknown)
            let names = SessionNamer(home: try temporaryDirectory()).names(for: sessions, records: records)
            #expect(names[session.id] == "Current conversation")
        }
    }

    @Test func plainCodexRejectsAmbiguousProcessesOrConversations() {
        let session = AgentSession(provider: .codex, pid: 20, startTime: 100, cwd: "/a")
        let second = AgentSession(provider: .codex, pid: 30, startTime: 100, cwd: "/a")
        let record = HookRecord(provider: .codex, sessionId: "current", state: .working, event: "PreToolUse",
                                cwd: "/a", pid: 10, pidStart: 50, updatedAt: 101)
        #expect(SessionMerger.merge([session, second], records: [record]).allSatisfy { $0.state == .unknown })
        var other = record
        other.sessionId = "another-conversation"
        other.updatedAt = 102
        #expect(SessionMerger.merge([session], records: [record, other])[0].state == .unknown)
        var resumed = session
        resumed.launchSessionId = "missing-conversation"
        #expect(SessionMerger.merge([resumed], records: [record])[0].state == .unknown)
    }

    @Test func plainCodexRejectsStaleEndedOrUnidentifiedRecords() {
        let session = AgentSession(provider: .codex, pid: 20, startTime: 100, cwd: "/a")
        let record = HookRecord(provider: .codex, sessionId: "current", state: .working, event: "PreToolUse",
                                cwd: "/a", pid: 10, pidStart: 50, updatedAt: 101)
        var stale = record
        stale.updatedAt = 99
        var ended = record
        ended.state = .exited
        ended.updatedAt = 102
        var unidentified = record
        unidentified.sessionId = ""
        var otherDirectory = record
        otherDirectory.cwd = "/b"
        for records in [[stale], [record, ended], [unidentified], [otherDirectory]] {
            #expect(SessionMerger.merge([session], records: records)[0].state == .unknown)
        }
        #expect(SessionMerger.merge([session], records: [stale, record])[0].state == .working)
    }

    @Test func directProcessMatchTakesPrecedenceOverResumedSession() {
        let session = AgentSession(provider: .codex, pid: 20, startTime: 100, cwd: "/a", launchSessionId: "resumed")
        let records = [
            HookRecord(provider: .codex, sessionId: "current", state: .idle, event: "Stop", cwd: "/a",
                       pid: 20, pidStart: 100, updatedAt: 101),
            HookRecord(provider: .codex, sessionId: "resumed", state: .working, event: "PreToolUse", cwd: "/a",
                       pid: 10, pidStart: 50, updatedAt: 102),
        ]
        let merged = SessionMerger.merge([session], records: records)[0]
        #expect(merged.state == .idle)
        #expect(merged.sessionId == "current")
    }

    @Test func latestMatchingRecordWins() {
        let session = AgentSession(provider: .claude, pid: 10, startTime: 100, cwd: "/a")
        let records = [
            HookRecord(provider: .claude, sessionId: "s", state: .working, event: "PreToolUse", cwd: "/a", pid: 10, pidStart: 100.4, updatedAt: 1),
            HookRecord(provider: .claude, sessionId: "s", state: .waiting, event: "Notification", cwd: "/a", pid: 10, pidStart: 100.4, updatedAt: 2),
            HookRecord(provider: .claude, sessionId: "old", state: .idle, event: "Stop", cwd: "/a", pid: 10, pidStart: 50, updatedAt: 3),
        ]
        #expect(SessionMerger.merge([session], records: records).first?.state == .waiting)
        #expect(SessionMerger.merge([session], records: []).first?.state == .unknown)
    }

    @Test func transitionsFollowEventOrder() {
        let session = AgentSession(provider: .claude, pid: 10, startTime: 100, cwd: "/a")
        var records: [HookRecord] = []
        var seen: [PetState] = []
        for (index, event) in ["SessionStart", "UserPromptSubmit", "Notification", "PreToolUse", "Stop"].enumerated() {
            let record = HookEvents.record(provider: .claude, payload: ["hook_event_name": event, "session_id": "s"],
                                           agent: (pid: 10, start: 100), now: Date(timeIntervalSince1970: Double(index)))!
            records.append(record)
            seen.append(SessionMerger.merge([session], records: records)[0].state)
        }
        #expect(seen == [.idle, .working, .waiting, .working, .idle])
    }

    @Test func classifiesAgentProcesses() {
        #expect(AgentClassifier.provider(comm: "claude", path: "/Users/u/.local/bin/claude", arguments: ["claude"]) == .claude)
        #expect(AgentClassifier.provider(comm: "2.1.302", path: "/Users/u/.local/share/claude/versions/2.1.302", arguments: []) == .claude)
        #expect(AgentClassifier.provider(comm: "node", path: "/opt/node", arguments: ["node", "/usr/local/bin/codex"]) == .codex)
        #expect(AgentClassifier.provider(comm: "node", path: "/opt/node", arguments: ["node", "server.js"]) == nil)
        #expect(AgentClassifier.isInteractive(arguments: ["claude", "--settings", "x.json"]))
        #expect(!AgentClassifier.isInteractive(arguments: ["claude", "daemon", "run"]))
        #expect(!AgentClassifier.isInteractive(arguments: ["claude", "attach", "abc"]))
        #expect(!AgentClassifier.isInteractive(arguments: ["claude", "-p", "hi"]))
    }

    @Test func scannerFindsNoSessionsForBogusPid() {
        #expect(ProcessTable.info(-5) == nil)
        #expect(!ProcessTable.all().isEmpty)
        #expect(ProcessTable.info(getpid())?.pid == getpid())
        // Root-owned processes (launchd here; `login` in a real terminal) must still be readable.
        #expect(ProcessTable.info(1)?.ppid == 0)
        #expect(ProcessTable.ancestors(of: getpid()).first?.pid == getpid())
    }
}

@Suite struct ConfigTests {
    @Test func roundTripsAndToleratesMissingFields() throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("nested/config.json")
        var config = AppConfig(showPets: false, petSize: 128)
        config.bindings = [PetBinding(provider: .codex, cwd: "/p", character: "ghost", pid: 3, pidStart: 4, x: 10, y: 20)]
        config.rememberCharacter(from: config.bindings[0])
        try config.save(to: url)
        #expect(AppConfig.load(from: url) == config)

        try Data(#"{"petSize": 64}"#.utf8).write(to: url)
        let partial = AppConfig.load(from: url)
        #expect(partial.petSize == 64 && partial.showPets && partial.bindings.isEmpty)
        #expect(partial.language == .system && partial.directoryPets.isEmpty)

        try Data("not json".utf8).write(to: url)
        #expect(AppConfig.load(from: url) == AppConfig())
    }

    @Test func reattachesBindingAfterRestart() {
        var config = AppConfig(bindings: [PetBinding(provider: .claude, cwd: "/work/app", character: "cat",
                                                    pid: 100, pidStart: 1000, x: 12, y: 34)])
        let restarted = [
            AgentSession(provider: .codex, pid: 300, startTime: 3000, cwd: "/work/app"),
            AgentSession(provider: .claude, pid: 200, startTime: 2000, cwd: "/work/app"),
            AgentSession(provider: .claude, pid: 250, startTime: 2500, cwd: "/work/app"),
        ]
        let resolved = BindingResolver.resolve(&config, sessions: restarted, characters: ["cat", "ghost", "dragon"], choose: { $0.first })
        #expect(config.bindings.map(\.character) == ["cat", "ghost", "dragon"])
        #expect(resolved[config.bindings[0].id] == restarted[1].id)
        #expect(config.bindings[0].pid == 200 && config.bindings[0].pidStart == 2000)
        #expect(config.bindings[0].x == 12 && config.bindings[0].y == 34)
        #expect(config.directoryPets["/work/app"]?.character == "cat")
    }

    @Test func exactMatchesAreNotStolen() {
        let a = PetBinding(provider: .claude, cwd: "/w", character: "cat", pid: 2, pidStart: 20)
        let b = PetBinding(provider: .claude, cwd: "/w", character: "ghost", pid: 99, pidStart: 1)
        var config = AppConfig(bindings: [b, a])
        let sessions = [AgentSession(provider: .claude, pid: 1, startTime: 10, cwd: "/w"),
                        AgentSession(provider: .claude, pid: 2, startTime: 20, cwd: "/w")]
        let resolved = BindingResolver.resolve(&config, sessions: sessions, characters: ["cat", "ghost"], choose: { $0.first })
        #expect(resolved[a.id] == sessions[1].id)
        #expect(config.bindings[0].character == "ghost" && config.bindings[0].pid == 1)
        #expect(config.bindings[1] == a)
        #expect(!config.bindings.contains { $0.id == b.id })
    }

    @Test func endedBindingsBecomeDirectoryPreferences() {
        var config = AppConfig(bindings: [PetBinding(provider: .claude, cwd: "/gone", character: "cat", pid: 5, pidStart: 5)])
        let session = AgentSession(provider: .codex, pid: 6, startTime: 6, cwd: "/other")
        let resolved = BindingResolver.resolve(&config, sessions: [session], characters: ["cat", "ghost"], choose: { $0.last })
        #expect(config.bindings.count == 1 && config.bindings[0].pid == 6)
        #expect(resolved[config.bindings[0].id] == session.id)
        #expect(config.directoryPets["/gone"]?.character == "cat")
        #expect(config.directoryPets["/other"]?.character == "ghost")
    }
}

@Suite struct HookInstallerTests {
    private func installer(_ home: URL) -> HookInstaller {
        HookInstaller(paths: AppPaths(home: home), hookExecutable: "/Applications/Desk Pets.app/Contents/MacOS/deskpets-hook",
                      now: { Date(timeIntervalSince1970: 1_700_000_000) })
    }

    private func json(_ url: URL) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    @Test func installKeepsUserHooksAndBacksUp() throws {
        let home = try temporaryDirectory()
        let settings = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = #"{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}"#
        try Data(original.utf8).write(to: settings)

        let changes = try installer(home).install([.claude])
        #expect(changes.count == 1)
        let backup = try #require(changes[0].backup)
        #expect(backup.lastPathComponent.hasPrefix("settings.json.deskpets-"))
        #expect(String(decoding: try Data(contentsOf: backup), as: UTF8.self) == original)

        let config = try json(settings)
        #expect(config["model"] as? String == "opus")
        let hooks = try #require(config["hooks"] as? [String: Any])
        let stop = try #require(hooks["Stop"] as? [[String: Any]])
        #expect(stop.count == 2)
        #expect(String(describing: stop[0]).contains("say done"))
        #expect(Set(hooks.keys) == Set(HookInstaller.claudeEvents))
        #expect(installer(home).isInstalled(.claude))
        #expect(!installer(home).isInstalled(.codex))

        // Installing twice changes nothing.
        #expect(try installer(home).install([.claude]).isEmpty)
    }

    @Test func uninstallRestoresOnlyUserHooks() throws {
        let home = try temporaryDirectory()
        let settings = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}"#.utf8).write(to: settings)
        try installer(home).install([.claude])
        try installer(home).uninstall([.claude])

        let hooks = try #require(try json(settings)["hooks"] as? [String: Any])
        #expect(Array(hooks.keys) == ["Stop"])
        #expect(!installer(home).isInstalled(.claude))
    }

    @Test func createsMissingFilesAndRefusesBrokenOnes() throws {
        let home = try temporaryDirectory()
        let changes = try installer(home).install([.codex])
        #expect(changes.first?.backup == nil)
        #expect(installer(home).isInstalled(.codex))
        let command = String(decoding: try Data(contentsOf: home.appendingPathComponent(".codex/hooks.json")), as: UTF8.self)
        #expect(command.contains("'/Applications/Desk Pets.app/Contents/MacOS/deskpets-hook' record --provider codex"))

        // Nothing to remove when the file never existed.
        #expect(try installer(home).uninstall([.claude]).isEmpty)

        let settings = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ broken".utf8).write(to: settings)
        #expect(throws: (any Error).self) { try installer(home).install([.claude]) }
        #expect(String(decoding: try Data(contentsOf: settings), as: UTF8.self) == "{ broken")
    }
}

@Suite struct CharacterLibraryTests {
    private func gif(in directory: URL, name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("GIF89a-fake".utf8).write(to: url)
        return url
    }

    @Test func sortsByNumericEMIDWithLegacyAndCustomCharactersPreserved() throws {
        let root = try temporaryDirectory()
        let entries: [(String, Int?, Bool)] = [
            ("a-late", 160, true), ("b-early", 2, true), ("c-middle", 11, true),
            ("d-same-id", 2, true), ("a-legacy", nil, true),
            ("custom-10", nil, false), ("custom-2", nil, false),
        ]
        for (name, emID, builtIn) in entries {
            let directory = root.appendingPathComponent("\(builtIn ? "builtin" : "custom")/\(name)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            _ = try gif(in: directory, name: "idle.gif")
            if let emID {
                try Data("{\"emID\":\(emID)}".utf8).write(to: directory.appendingPathComponent("character.json"))
            }
        }
        let library = CharacterLibrary(builtInRoot: root.appendingPathComponent("builtin"),
                                       customRoot: root.appendingPathComponent("custom"))
        #expect(library.list().map(\.name) == [
            "b-early", "d-same-id", "c-middle", "a-late", "a-legacy", "custom-2", "custom-10",
        ])
        #expect(library.character(named: "a-late")?.emID == 160)
        #expect(library.character(named: "a-legacy")?.emID == nil)
    }

    @Test func importsListsAndDeletes() throws {
        let root = try temporaryDirectory()
        let builtIn = root.appendingPathComponent("builtin/cat", isDirectory: true)
        try FileManager.default.createDirectory(at: builtIn, withIntermediateDirectories: true)
        _ = try gif(in: builtIn, name: "idle.gif")
        let library = CharacterLibrary(builtInRoot: root.appendingPathComponent("builtin"), customRoot: root.appendingPathComponent("custom"))

        let idle = try gif(in: root, name: "a.gif")
        let character = try library.importCharacter(name: "  Mochi ", idle: idle)
        #expect(character.name == "Mochi")
        #expect(character.displayScale == 1)
        #expect(library.list().map(\.name) == ["cat", "Mochi"])
        // Missing optional animations fall back to idle.
        #expect(character.gif(for: .working).lastPathComponent == "idle.gif")

        #expect(throws: CharacterError.alreadyExists("Mochi")) { try library.importCharacter(name: "Mochi", idle: idle) }
        #expect(throws: CharacterError.invalidName) { try library.importCharacter(name: "../x", idle: idle) }
        let text = root.appendingPathComponent("b.gif")
        try Data("hello".utf8).write(to: text)
        #expect(throws: CharacterError.notAGIF("b.gif")) { try library.importCharacter(name: "Bad", idle: text) }

        #expect(throws: CharacterError.builtIn) { try library.delete(library.character(named: "cat")!) }
        try library.delete(character)
        #expect(library.list().map(\.name) == ["cat"])
    }

    @Test(arguments: [
        (#"{"displayScale":1.2}"#, 1.2),
        (#"{"displayScale":0}"#, 1.0),
        (#"{"displayScale":3}"#, 1.0),
        ("{}", 1.0),
        ("broken", 1.0),
    ])
    func readsCharacterScale(options: String, expected: Double) throws {
        let root = try temporaryDirectory()
        let directory = root.appendingPathComponent("custom/Ice")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = try gif(in: directory, name: "idle.gif")
        try Data(options.utf8).write(to: directory.appendingPathComponent("character.json"))
        let library = CharacterLibrary(builtInRoot: nil, customRoot: root.appendingPathComponent("custom"))
        #expect(library.character(named: "Ice")?.displayScale == expected)
    }
}

@Suite struct CmuxAndProcArgsTests {
    @Test func parsesArgumentsAndEnvironmentFromProcArgs() {
        var buffer = withUnsafeBytes(of: Int32(2)) { Array($0) }
        buffer += Array("/usr/local/bin/claude".utf8) + [0, 0, 0]
        for string in ["claude", "--resume", "CMUX_WORKSPACE_ID=07A6C580-8369-4084-B1A9-312A57B0AE61", "EMPTY=", "A=b=c"] {
            buffer += Array(string.utf8) + [0]
        }
        buffer += [0, 0]
        let parsed = ProcessTable.parseProcArgs(buffer)
        #expect(parsed.arguments == ["claude", "--resume"])
        #expect(parsed.environment == ["CMUX_WORKSPACE_ID": "07A6C580-8369-4084-B1A9-312A57B0AE61", "EMPTY": "", "A": "b=c"])
        #expect(ProcessTable.parseProcArgs([1, 0]) .arguments.isEmpty)
    }

    @Test func readsOwnEnvironment() {
        setenv("DESKPETS_TEST_MARKER", "42", 1)
        // KERN_PROCARGS2 shows the environment at exec time, so only check that parsing yields something.
        #expect(!ProcessTable.commandLine(getpid()).arguments.isEmpty)
    }

    @Test func cmuxLocationFromEnvironment() {
        let env = ["CMUX_WORKSPACE_ID": "07A6C580-8369-4084-B1A9-312A57B0AE61",
                   "CMUX_SURFACE_ID": "B5C9EAD5-EB0D-4CB2-9AF7-D7854CC6BBE3",
                   "CMUX_BUNDLED_CLI_PATH": "/Applications/cmux.app/Contents/Resources/bin/cmux"]
        let location = CmuxLocation.from(environment: env)
        #expect(location == CmuxLocation(workspaceId: "07A6C580-8369-4084-B1A9-312A57B0AE61",
                                         surfaceId: "B5C9EAD5-EB0D-4CB2-9AF7-D7854CC6BBE3",
                                         cli: "/Applications/cmux.app/Contents/Resources/bin/cmux"))
        #expect(CmuxLocation.from(environment: ["CMUX_WORKSPACE_ID": "07A6C580-8369-4084-B1A9-312A57B0AE61"]) == nil)
        #expect(CmuxLocation.from(environment: ["CMUX_WORKSPACE_ID": "x; rm -rf /", "CMUX_SURFACE_ID": "y"]) == nil)
        #expect(CmuxLocation.from(environment: [:]) == nil)
    }

    @Test func focusRunsSelectThenFocusPanel() {
        var calls: [[String]] = []
        let location = CmuxLocation(workspaceId: "W", surfaceId: "S", cli: "/bin/cmux")
        let ok = CmuxControl.focus(location) { cli, args in
            calls.append([cli] + args)
            return Data()
        }
        #expect(ok)
        #expect(calls == [["/bin/cmux", "select-workspace", "--workspace", "W"],
                          ["/bin/cmux", "focus-panel", "--panel", "S", "--workspace", "W"]])
        #expect(!CmuxControl.focus(location) { _, _ in nil })
    }

    @Test func sessionIdFromArguments() {
        #expect(AgentClassifier.sessionId(arguments: ["claude", "--resume", "BA41FA31-C0A7-42D7-B5D1-59516579B291"]) == "ba41fa31-c0a7-42d7-b5d1-59516579b291")
        #expect(AgentClassifier.sessionId(arguments: ["claude", "--session-id", "d95385b3-f96a-42d1-af1c-227ee3e08650", "-x"]) == "d95385b3-f96a-42d1-af1c-227ee3e08650")
        #expect(AgentClassifier.sessionId(arguments: ["claude", "--resume"]) == nil)
        #expect(AgentClassifier.sessionId(arguments: ["claude", "--resume", "not-a-uuid"]) == nil)
    }

    @Test func codexResumeSessionIdFromArguments() {
        let id = "BA41FA31-C0A7-42D7-B5D1-59516579B291"
        #expect(AgentClassifier.sessionId(arguments: ["codex", "resume", id]) == id.lowercased())
        #expect(AgentClassifier.sessionId(arguments: ["/usr/local/bin/codex", "resume", id, "Continue"]) == id.lowercased())
        #expect(AgentClassifier.sessionId(arguments: ["codex", "resume", "--last"]) == nil)
        #expect(AgentClassifier.sessionId(arguments: ["codex", "resume"]) == nil)
        #expect(AgentClassifier.sessionId(arguments: ["codex", "fork", id]) == nil)
        #expect(AgentClassifier.sessionId(arguments: ["codex", "--model", "resume", id]) == nil)
        #expect(AgentClassifier.sessionId(arguments: ["claude", "resume", id]) == nil)
    }

    @Test func surfaceTitlesFromTree() {
        let json = #"""
        {"windows":[{"id":"W1","title":"window","workspaces":[{"id":"WS","title":"workspace title","panes":[
          {"id":"P","surfaces":[{"id":"b5c9ead5-eb0d-4cb2-9af7-d7854cc6bbe3","title":"✳ Mochi shop"},{"id":"S2","title":"⠂ busy"}]}]}]}]}
        """#
        let titles = CmuxTree.surfaceTitles(from: Data(json.utf8))
        #expect(titles == ["B5C9EAD5-EB0D-4CB2-9AF7-D7854CC6BBE3": "Mochi shop", "S2": "busy"])
        #expect(CmuxTree.cleanTitle("claude demo-search") == "claude demo-search")
        #expect(CmuxTree.surfaceTitles(from: Data("nope".utf8)).isEmpty)
    }
}

@Suite struct SessionNameTests {
    private func temporaryHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("deskpets-names-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func codexTitlesFollowSessionIndexAndRefreshAfterRename() throws {
        let home = try temporaryHome()
        let folder = home.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let index = folder.appendingPathComponent("session_index.jsonl")
        let id = "11111111-1111-1111-1111-111111111111"
        let otherId = "22222222-2222-2222-2222-222222222222"
        try Data("{\"id\":\"\(id)\",\"thread_name\":\"  魔物桌寵  \",\"updated_at\":\"2026-10-22T10:00:00Z\"}\n".utf8).write(to: index)
        let sessions = [
            AgentSession(provider: .codex, pid: 1, startTime: 100, cwd: "/a", launchSessionId: id),
            AgentSession(provider: .codex, pid: 2, startTime: 100, cwd: "/a", launchSessionId: otherId),
            AgentSession(provider: .claude, pid: 3, startTime: 100, cwd: "/a", launchSessionId: id),
        ]
        let namer = SessionNamer(home: home)
        let now = Date()
        let names = namer.names(for: sessions, records: [], now: now)
        #expect(names[sessions[0].id] == "魔物桌寵")
        #expect(names[sessions[1].id] == nil)
        #expect(names[sessions[2].id] == nil)

        let handle = try FileHandle(forWritingTo: index)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"id\":\"\(id)\",\"thread_name\":\"重新命名\"}\n{\"id\":".utf8))
        try handle.close()
        #expect(namer.names(for: sessions, records: [], now: now.addingTimeInterval(5))[sessions[0].id] == "魔物桌寵")
        #expect(namer.names(for: sessions, records: [], now: now.addingTimeInterval(60))[sessions[0].id] == "重新命名")

        try FileManager.default.removeItem(at: index)
        #expect(namer.names(for: sessions, records: [], now: now.addingTimeInterval(120))[sessions[0].id] == nil)
    }

    @Test func codexIndexUsesCurrentHookSessionAndPreservesFallback() throws {
        let home = try temporaryHome()
        let folder = home.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let current = "11111111-1111-1111-1111-111111111111"
        let previous = "22222222-2222-2222-2222-222222222222"
        let lines = [
            "{\"id\":\"\(previous)\",\"thread_name\":\"Old conversation\"}",
            "{\"id\":\"\(current)\",\"thread_name\":\"Current conversation\"}",
            "{\"id\":\"\(current)\",\"thread_name\":42}",
        ]
        try Data(lines.joined(separator: "\n").utf8).write(to: folder.appendingPathComponent("session_index.jsonl"))
        let session = AgentSession(provider: .codex, pid: 1, startTime: 100, cwd: "/a", launchSessionId: previous)
        var record = HookRecord(provider: .codex, sessionId: current, state: .idle, event: "Stop", cwd: "/a",
                                pid: 1, pidStart: 100, title: "Hook title", updatedAt: 101)
        let namer = SessionNamer(home: home)
        #expect(namer.names(for: [session], records: [record])[session.id] == "Current conversation")
        record.sessionId = "33333333-3333-3333-3333-333333333333"
        #expect(namer.names(for: [session], records: [record])[session.id] == "Hook title")
    }

    @Test func parsesLastTitlesAndIgnoresMentionsInMessages() {
        let lines = [
            #"{"type":"ai-title","aiTitle":"First AI title","sessionId":"s"}"#,
            #"{"type":"custom-title","customTitle":"old name","sessionId":"s"}"#,
            #"{"type":"user","message":{"content":"please write \"customTitle\":\"fake\" in a test"}}"#,
            #"{"type":"custom-title","customTitle":"Weekend hack","sessionId":"s"}"#,
            #"{"type":"assistant","message":{"content":"done"}}"#,
            #"partial line {"type":"custom-title","customTitle":"#,
        ]
        let titles = TranscriptReader.parse(Data(lines.joined(separator: "\n").utf8))
        #expect(titles == TranscriptTitles(customTitle: "Weekend hack", aiTitle: "First AI title"))
        #expect(TranscriptReader.parse(Data()) == TranscriptTitles())
    }

    @Test func readsOnlyTheTailOfLargeFilesAndHeadForAITitle() throws {
        let home = try temporaryHome()
        let url = home.appendingPathComponent("big.jsonl")
        var data = Data(#"{"type":"ai-title","aiTitle":"Early AI title"}"#.utf8 + [0x0a])
        data += Data(#"{"type":"custom-title","customTitle":"too early"}"#.utf8 + [0x0a])
        let filler = Data((#"{"type":"user","message":"\#(String(repeating: "x", count: 1000))"}"#).utf8 + [0x0a])
        for _ in 0..<(TranscriptReader.tailBytes / filler.count + 10) { data += filler }
        data += Data(#"{"type":"custom-title","customTitle":"Recent"}"#.utf8 + [0x0a])
        try data.write(to: url)
        let read = TranscriptReader.read(url)
        #expect(read.titles == TranscriptTitles(customTitle: "Recent", aiTitle: "Early AI title"))
        #expect(read.size == UInt64(data.count))
    }

    @Test func transcriptPathFollowsClaudeLayout() {
        let url = TranscriptReader.path(home: URL(fileURLWithPath: "/h"), cwd: "/Users/me/Developer/apps/my_app.v2",
                                        sessionId: "abc")
        #expect(url.path == "/h/.claude/projects/-Users-me-Developer-apps-my-app-v2/abc.jsonl")
    }

    @Test func namesFollowPriorityAndCache() throws {
        let home = try temporaryHome()
        let cwd = "/work/app"
        let renamed = "11111111-1111-1111-1111-111111111111"
        let aiOnly = "22222222-2222-2222-2222-222222222222"
        let folder = home.appendingPathComponent(".claude/projects/-work-app")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"aiTitle":"AI one"}"# .utf8 + [0x0a] + #"{"customTitle":"Renamed"}"#.utf8).write(to: folder.appendingPathComponent("\(renamed).jsonl"))
        try Data(#"{"aiTitle":"AI two"}"#.utf8).write(to: folder.appendingPathComponent("\(aiOnly).jsonl"))

        let surface = "B5C9EAD5-EB0D-4CB2-9AF7-D7854CC6BBE3"
        let cmux = CmuxLocation(workspaceId: "07A6C580-8369-4084-B1A9-312A57B0AE61", surfaceId: surface, cli: "/fake/cmux")
        let sessions = [
            AgentSession(provider: .claude, pid: 1, startTime: 1, cwd: cwd, cmux: cmux, launchSessionId: renamed),  // rename beats cmux
            AgentSession(provider: .claude, pid: 2, startTime: 2, cwd: cwd, cmux: cmux),                             // id from hook record
            AgentSession(provider: .claude, pid: 3, startTime: 3, cwd: cwd, launchSessionId: aiOnly),               // AI title only
            AgentSession(provider: .claude, pid: 4, startTime: 4, cwd: cwd),                                        // nothing known
        ]
        let records = [HookRecord(provider: .claude, sessionId: "33333333-3333-3333-3333-333333333333", state: .idle,
                                  event: "Stop", cwd: cwd, pid: 2, pidStart: 2, updatedAt: 1)]
        let namer = SessionNamer(home: home)
        var cmuxCalls = 0
        namer.runCmux = { _, _ in
            cmuxCalls += 1
            return Data(#"{"windows":[{"workspaces":[{"panes":[{"surfaces":[{"id":"\#(surface)","title":"✳ Mochi shop"}]}]}]}]}"#.utf8)
        }
        let now = Date()
        let names = namer.names(for: sessions, records: records, now: now)
        #expect(names[sessions[0].id] == "Renamed")
        #expect(names[sessions[1].id] == "Mochi shop")
        #expect(names[sessions[2].id] == "AI two")
        #expect(names[sessions[3].id] == nil)
        #expect(sessions[3].displayName == "app · PID 4")

        // Within the cache windows neither cmux nor the transcripts are read again. Transcripts are append-only.
        let handle = try FileHandle(forWritingTo: folder.appendingPathComponent("\(aiOnly).jsonl"))
        handle.seekToEndOfFile()
        handle.write(Data("\n{\"customTitle\":\"Changed\"}".utf8))
        try handle.close()
        _ = namer.names(for: sessions, records: records, now: now.addingTimeInterval(5))
        #expect(cmuxCalls == 1)
        #expect(namer.names(for: sessions, records: records, now: now.addingTimeInterval(5))[sessions[2].id] == "AI two")
        #expect(namer.names(for: sessions, records: records, now: now.addingTimeInterval(60))[sessions[2].id] == "Changed")
        #expect(cmuxCalls == 2)
    }

    @Test func incrementalReadKeepsEarlierTitles() throws {
        let home = try temporaryHome()
        let id = "44444444-4444-4444-4444-444444444444"
        let folder = home.appendingPathComponent(".claude/projects/-w")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(id).jsonl")
        try Data(#"{"customTitle":"Kept"}"#.utf8 + [0x0a]).write(to: url)
        let namer = SessionNamer(home: home)
        let session = AgentSession(provider: .claude, pid: 9, startTime: 9, cwd: "/w", launchSessionId: id)
        let now = Date()
        #expect(namer.names(for: [session], records: [], now: now)[session.id] == "Kept")
        let handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        handle.write(Data(#"{"type":"assistant","message":"no titles here"}"#.utf8 + [0x0a]))
        try handle.close()
        #expect(namer.names(for: [session], records: [], now: now.addingTimeInterval(60))[session.id] == "Kept")
    }

    @Test func hookRecordKeepsTranscriptPath() throws {
        let record = try #require(HookEvents.record(provider: .claude,
                                                    payload: ["hook_event_name": "Stop", "session_id": "s", "transcript_path": "/x/s.jsonl"],
                                                    agent: nil))
        #expect(record.transcriptPath == "/x/s.jsonl")
        let old = #"{"provider":"claude","sessionId":"s","state":"idle","event":"Stop","cwd":"","pid":1,"pidStart":0,"updatedAt":0}"#
        #expect(try JSONDecoder().decode(HookRecord.self, from: Data(old.utf8)).transcriptPath == nil)
    }
}

@Suite struct ChunkedReadTests {
    @Test func titlesSplitAcrossChunkBoundariesAreFound() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("deskpets-chunk-\(UUID().uuidString).jsonl")
        var data = Data()
        data += Data(#"{"type":"ai-title","aiTitle":"Across"}"#.utf8 + [0x0a])
        for index in 0..<200 { data += Data(#"{"n":\#(index),"pad":"\#(String(repeating: "y", count: 37))"}"#.utf8 + [0x0a]) }
        data += Data(#"{"type":"custom-title","customTitle":"Split line"}"#.utf8 + [0x0a])
        data += Data(#"{"tail":true}"#.utf8)
        try data.write(to: url)
        // Tiny chunks force every line, including the title lines, to straddle a boundary somewhere.
        for chunk in [7, 13, 64, 1000] {
            let read = TranscriptReader.read(url, chunkSize: chunk)
            #expect(read.titles == TranscriptTitles(customTitle: "Split line", aiTitle: "Across"), "chunk \(chunk)")
        }
        // Reading only what was appended after the old size finds nothing new.
        #expect(TranscriptReader.read(url, after: UInt64(data.count)).titles == TranscriptTitles())
    }
}
