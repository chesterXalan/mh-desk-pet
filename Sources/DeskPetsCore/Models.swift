import Foundation

public enum Provider: String, Codable, Sendable, CaseIterable {
    case claude, codex
}

public enum PetState: String, Codable, Sendable {
    case working, waiting, idle, unknown, exited

    /// The animation a pet plays for this state. Without hooks we only know "unknown", which looks idle.
    public var animation: String {
        switch self {
        case .working: return "working"
        case .waiting: return "waiting"
        case .idle, .unknown, .exited: return "idle"
        }
    }
}

/// All on-disk locations, derived from one home directory so tests can use a temporary HOME.
public struct AppPaths: Sendable {
    public let home: URL

    public init(home: URL) {
        self.home = home
    }

    public static func current() -> AppPaths {
        if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty {
            return AppPaths(home: URL(fileURLWithPath: home, isDirectory: true))
        }
        return AppPaths(home: FileManager.default.homeDirectoryForCurrentUser)
    }

    public var support: URL { home.appendingPathComponent("Library/Application Support/DeskPets", isDirectory: true) }
    public var sessions: URL { support.appendingPathComponent("sessions", isDirectory: true) }
    public var characters: URL { support.appendingPathComponent("characters", isDirectory: true) }
    public var config: URL { support.appendingPathComponent("config.json") }
    public var hookErrors: URL { support.appendingPathComponent("hook-errors.log") }
    public var claudeSettings: URL { home.appendingPathComponent(".claude/settings.json") }
    public var codexHooks: URL { home.appendingPathComponent(".codex/hooks.json") }
}

/// A live claude/codex session: a detected process, optionally enriched by hook records.
public struct AgentSession: Identifiable, Equatable, Sendable {
    public var provider: Provider
    public var pid: Int32
    public var startTime: Double
    public var cwd: String
    public var state: PetState
    public var sessionId: String?
    public var title: String?
    /// The cmux tab hosting the session, read from the process environment.
    public var cmux: CmuxLocation?
    public var tmux: TmuxLocation?
    /// Conversation ID from launch arguments (`--session-id`, `--resume`, or Codex `resume UUID`).
    public var launchSessionId: String?

    public init(provider: Provider, pid: Int32, startTime: Double, cwd: String,
                state: PetState = .unknown, sessionId: String? = nil, title: String? = nil,
                cmux: CmuxLocation? = nil, launchSessionId: String? = nil, tmux: TmuxLocation? = nil) {
        self.provider = provider
        self.pid = pid
        self.startTime = startTime
        self.cwd = cwd
        self.state = state
        self.sessionId = sessionId
        self.title = title
        self.cmux = cmux
        self.tmux = tmux
        self.launchSessionId = launchSessionId
    }

    public var id: String { "\(provider.rawValue):\(pid):\(Int(startTime))" }

    public var folderName: String {
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty || name == "/" ? cwd : name
    }

    /// Directory and explicitly labeled PID for identifying sessions in the list.
    public var location: String { "\(folderName) · PID \(pid)" }

    /// The friendly name (/rename, cmux tab, or AI title) when known, else the location.
    public var displayName: String {
        if let title, !title.isEmpty { return title }
        return location
    }
}

/// A cmux workspace + surface (tab), taken from CMUX_WORKSPACE_ID / CMUX_SURFACE_ID.
public struct CmuxLocation: Codable, Equatable, Hashable, Sendable {
    public var workspaceId: String
    public var surfaceId: String
    /// The cmux CLI that launched the session (CMUX_BUNDLED_CLI_PATH), if known.
    public var cli: String?

    public init(workspaceId: String, surfaceId: String, cli: String? = nil) {
        self.workspaceId = workspaceId
        self.surfaceId = surfaceId
        self.cli = cli
    }

    public static func from(environment: [String: String]) -> CmuxLocation? {
        guard let workspace = environment["CMUX_WORKSPACE_ID"], UUID(uuidString: workspace) != nil,
              let surface = environment["CMUX_SURFACE_ID"] ?? environment["CMUX_PANEL_ID"], UUID(uuidString: surface) != nil
        else { return nil }
        let cli = environment["CMUX_BUNDLED_CLI_PATH"].flatMap { $0.hasPrefix("/") ? $0 : nil }
        return CmuxLocation(workspaceId: workspace, surfaceId: surface, cli: cli)
    }
}

/// Distributed notification that shows or hides all pets (object: "show" or "hide").
public enum PetsSwitch {
    public static let name = Notification.Name("io.github.youngoman.deskpets.pets")
    public static let show = "show"
    public static let hide = "hide"
}
