import Foundation

public struct TmuxLocation: Equatable, Sendable {
    public var socketPath: String
    public var paneId: String

    public static func from(environment: [String: String]) -> TmuxLocation? {
        guard let value = environment["TMUX"], let pane = environment["TMUX_PANE"],
              pane.first == "%", !pane.dropFirst().isEmpty, pane.dropFirst().allSatisfy(\.isNumber)
        else { return nil }
        let fields = value.split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count >= 3, let server = Int32(fields[fields.count - 2]), server > 0,
              Int(fields.last!) != nil else { return nil }
        let socket = fields.dropLast(2).joined(separator: ",")
        guard socket.hasPrefix("/"), !socket.contains("\0") else { return nil }
        return TmuxLocation(socketPath: socket, paneId: pane)
    }
}

public struct TmuxClient: Equatable, Sendable {
    public var pid: Int32
    public var tty: String
    public var sessionId: String
    public var activity: Double
}

public enum TmuxControl {
    public static var defaultCLI: String {
        ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
            .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/tmux"
    }

    public static func clients(for location: TmuxLocation,
                               run: (String, [String]) -> Data? = SessionNamer.run) -> [TmuxClient] {
        let prefix = ["-S", location.socketPath]
        guard let sessionData = run(defaultCLI, prefix + ["display-message", "-p", "-t", location.paneId, "#{session_id}"]),
              let data = run(defaultCLI, prefix + ["list-clients", "-F",
                  "#{client_pid}\t#{client_tty}\t#{session_id}\t#{client_activity}\t#{client_control_mode}"])
        else { return [] }
        let targetSession = String(decoding: sessionData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line -> TmuxClient? in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 5, let pid = Int32(fields[0]), pid > 0,
                  fields[1].hasPrefix("/dev/"), let activity = Double(fields[3]), fields[4] == "0"
            else { return nil }
            return TmuxClient(pid: pid, tty: String(fields[1]), sessionId: String(fields[2]), activity: activity)
        }.sorted { left, right in
            let leftMatches = left.sessionId == targetSession
            let rightMatches = right.sessionId == targetSession
            if leftMatches != rightMatches { return leftMatches }
            return left.activity == right.activity ? left.pid < right.pid : left.activity > right.activity
        }
    }

    @discardableResult
    public static func focus(_ location: TmuxLocation, client: TmuxClient,
                             run: (String, [String]) -> Data? = SessionNamer.run) -> Bool {
        run(defaultCLI, ["-S", location.socketPath, "switch-client", "-E", "-c", client.tty,
                         "-t", location.paneId]) != nil
    }

    // Read the outer terminal's current title from the client's current session before switching panes.
    public static func terminalTitle(for location: TmuxLocation, client: TmuxClient,
                                     run: (String, [String]) -> Data? = SessionNamer.run) -> String? {
        guard let data = run(defaultCLI, ["-S", location.socketPath, "display-message", "-p", "-c", client.tty,
                                         "-t", client.sessionId, "#{?set-titles,#{T:set-titles-string},}"]) else { return nil }
        let title = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }
}
