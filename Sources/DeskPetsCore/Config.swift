import Foundation

/// Character and position for an active session; an empty character hides its pet.
public struct PetBinding: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var provider: Provider
    public var cwd: String
    public var character: String
    public var pid: Int32?
    public var pidStart: Double?
    public var x: Double?
    public var y: Double?

    public init(id: UUID = UUID(), provider: Provider, cwd: String, character: String,
                pid: Int32? = nil, pidStart: Double? = nil, x: Double? = nil, y: Double? = nil) {
        self.id = id
        self.provider = provider
        self.cwd = cwd
        self.character = character
        self.pid = pid
        self.pidStart = pidStart
        self.x = x
        self.y = y
    }

    public func matchesExactly(_ session: AgentSession) -> Bool {
        guard let pid, let pidStart else { return false }
        return session.provider == provider && session.pid == pid && abs(session.startTime - pidStart) < 2
    }
}

/// Preferred character and position for the next session in a directory, regardless of CLI provider.
public struct DirectoryPetPreference: Codable, Equatable, Sendable {
    public var character: String
    public var x: Double?
    public var y: Double?

    public init(character: String, x: Double? = nil, y: Double? = nil) {
        self.character = character
        self.x = x
        self.y = y
    }
}

/// Reusable position within a directory; keeps the binding ID after its session ends.
public struct PetPosition: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var x: Double
    public var y: Double
}

public struct AppConfig: Codable, Equatable, Sendable {
    public static let sizes = [64, 96, 128, 192, 256]
    public static let animationDurationRange = 0.4...6.0

    public var showPets = true
    public var petSize = 96
    public var animationDuration: Double?
    public var language: AppLanguage
    public var bindings: [PetBinding] = []
    public var directoryPets: [String: DirectoryPetPreference]
    public var directoryPositions: [String: [PetPosition]]
    public var home: PetHome

    public init(showPets: Bool = true, petSize: Int = 96, bindings: [PetBinding] = [],
                animationDuration: Double? = nil, language: AppLanguage = .system,
                directoryPets: [String: DirectoryPetPreference] = [:],
                directoryPositions: [String: [PetPosition]] = [:], home: PetHome = PetHome()) {
        self.showPets = showPets
        self.petSize = petSize
        self.bindings = bindings
        self.language = language
        self.directoryPets = directoryPets
        self.directoryPositions = directoryPositions
        self.home = home
        self.animationDuration = animationDuration.flatMap { Self.animationDurationRange.contains($0) ? $0 : nil }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        showPets = try container.decodeIfPresent(Bool.self, forKey: .showPets) ?? true
        petSize = try container.decodeIfPresent(Int.self, forKey: .petSize) ?? 96
        bindings = try container.decodeIfPresent([PetBinding].self, forKey: .bindings) ?? []
        directoryPets = try container.decodeIfPresent([String: DirectoryPetPreference].self, forKey: .directoryPets) ?? [:]
        directoryPositions = try container.decodeIfPresent([String: [PetPosition]].self, forKey: .directoryPositions) ?? [:]
        home = try container.decodeIfPresent(PetHome.self, forKey: .home) ?? PetHome()
        language = (try? container.decode(AppLanguage.self, forKey: .language)) ?? .system
        animationDuration = (try? container.decodeIfPresent(Double.self, forKey: .animationDuration))
            .flatMap { Self.animationDurationRange.contains($0) ? $0 : nil }
    }

    @discardableResult
    public mutating func migrateCharacterNames(using characters: [CharacterInfo]) -> Bool {
        var changed = false
        for index in bindings.indices {
            let oldName = bindings[index].character
            guard !characters.contains(where: { $0.name == oldName }),
                  let character = characters.first(where: { $0.builtIn && $0.aliases.contains(oldName) }) else { continue }
            bindings[index].character = character.name
            changed = true
        }
        for directory in Array(directoryPets.keys) {
            guard let oldName = directoryPets[directory]?.character,
                  !characters.contains(where: { $0.name == oldName }),
                  let character = characters.first(where: { $0.builtIn && $0.aliases.contains(oldName) }) else { continue }
            directoryPets[directory]?.character = character.name
            changed = true
        }
        return changed
    }

    public mutating func rememberCharacter(from binding: PetBinding) {
        guard !binding.character.isEmpty else { return }
        directoryPets[binding.cwd] = DirectoryPetPreference(character: binding.character, x: binding.x, y: binding.y)
        rememberPosition(from: binding)
    }

    public mutating func setPosition(_ id: UUID, x: Double, y: Double) {
        guard let index = bindings.firstIndex(where: { $0.id == id }) else { return }
        bindings[index].x = x
        bindings[index].y = y
        let binding = bindings[index]
        rememberPosition(from: binding)
        if directoryPets[binding.cwd]?.character == binding.character {
            directoryPets[binding.cwd]?.x = x
            directoryPets[binding.cwd]?.y = y
        }
    }

    private mutating func rememberPosition(from binding: PetBinding) {
        guard let x = binding.x, let y = binding.y else { return }
        let position = PetPosition(id: binding.id, x: x, y: y)
        if let index = directoryPositions[binding.cwd]?.firstIndex(where: { $0.id == binding.id }) {
            directoryPositions[binding.cwd]?[index] = position
        } else {
            directoryPositions[binding.cwd, default: []].append(position)
        }
    }

    fileprivate mutating func rememberPositions() {
        // Save positions from legacy active bindings before removing ended sessions.
        for binding in bindings { rememberPosition(from: binding) }
        for (directory, preference) in directoryPets where directoryPositions[directory, default: []].isEmpty {
            guard let x = preference.x, let y = preference.y else { continue }
            directoryPositions[directory] = [PetPosition(id: UUID(), x: x, y: y)]
        }
    }

    /// Missing or unreadable config yields defaults; a broken file is never fatal.
    public static func load(from url: URL) -> AppConfig {
        guard let data = try? Data(contentsOf: url) else { return AppConfig() }
        return (try? JSONDecoder().decode(AppConfig.self, from: data)) ?? AppConfig()
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

public enum BindingResolver {
    /// Keep active bindings, choose characters for new sessions, and remove ended sessions.
    /// Prefer the saved character for the first pet in each directory, then avoid characters already in use.
    public static func resolve(_ config: inout AppConfig, sessions: [AgentSession], characters: [String],
                               choose: ([String]) -> String? = { $0.randomElement() }) -> [UUID: String] {
        let available = Set(characters)
        for binding in config.bindings where config.directoryPets[binding.cwd] == nil && available.contains(binding.character) {
            config.rememberCharacter(from: binding)
        }
        config.rememberPositions()
        let retained = config.bindings.filter { binding in
            (binding.character.isEmpty || available.contains(binding.character)) && sessions.contains(where: binding.matchesExactly)
        }
        var occupiedPositions = Set(config.bindings.filter { binding in
            sessions.contains(where: binding.matchesExactly)
        }.map(\.id))
        var usedCharacters = Set(retained.map(\.character))
        var visitedDirectories = Set<String>()
        var active: [PetBinding] = []
        var result: [UUID: String] = [:]
        for session in sessions.sorted(by: { $0.startTime < $1.startTime }) {
            let firstInDirectory = visitedDirectories.insert(session.cwd).inserted
            if let binding = retained.first(where: { $0.matchesExactly(session) && result[$0.id] == nil }) {
                active.append(binding)
                result[binding.id] = session.id
                continue
            }
            let preference = config.directoryPets[session.cwd]
            let unused = characters.filter { !usedCharacters.contains($0) }
            let localCharacters = Set((retained + active).filter { $0.cwd == session.cwd }.map(\.character))
            let locallyUnused = characters.filter { !localCharacters.contains($0) }
            let candidates = !unused.isEmpty ? unused : (!locallyUnused.isEmpty ? locallyUnused : characters)
            let remembered = firstInDirectory ? preference?.character : nil
            guard let character = remembered.flatMap({ available.contains($0) ? $0 : nil }) ?? choose(candidates) else { continue }
            let existing = config.bindings.first { $0.matchesExactly(session) }
            let position = config.directoryPositions[session.cwd]?.first { $0.id == existing?.id }
                ?? config.directoryPositions[session.cwd]?.first { !occupiedPositions.contains($0.id) }
            let legacy = firstInDirectory && config.directoryPositions[session.cwd, default: []].isEmpty ? preference : nil
            let binding = PetBinding(id: existing?.id ?? position?.id ?? UUID(), provider: session.provider, cwd: session.cwd,
                                     character: character, pid: session.pid, pidStart: session.startTime,
                                     x: existing?.x ?? position?.x ?? legacy?.x,
                                     y: existing?.y ?? position?.y ?? legacy?.y)
            active.append(binding)
            occupiedPositions.insert(binding.id)
            result[binding.id] = session.id
            usedCharacters.insert(character)
            if preference.map({ !available.contains($0.character) }) ?? true {
                config.rememberCharacter(from: binding)
            }
        }
        config.bindings = active
        return result
    }
}
