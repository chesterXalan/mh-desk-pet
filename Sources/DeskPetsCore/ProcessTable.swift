import Darwin
import Foundation

public struct ProcessSnapshot: Sendable, Equatable {
    public var pid: Int32
    public var ppid: Int32
    public var startTime: Double
    public var comm: String
    public var hasTTY: Bool
}

/// Process inspection through sysctl and libproc, so scanning never forks `ps`.
public enum ProcessTable {
    public static func all() -> [ProcessSnapshot] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: getuid())]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0 else { return [] }
        let stride = MemoryLayout<kinfo_proc>.stride
        size += stride * 32
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride)
        guard sysctl(&mib, UInt32(mib.count), &procs, &size, nil, 0) == 0 else { return [] }
        return procs.prefix(size / stride).map(snapshot)
    }

    private static func snapshot(_ proc: kinfo_proc) -> ProcessSnapshot {
        var comm = proc.kp_proc.p_comm
        let name = withUnsafeBytes(of: &comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let start = proc.kp_proc.p_starttime
        return ProcessSnapshot(pid: proc.kp_proc.p_pid,
                               ppid: proc.kp_eproc.e_ppid,
                               startTime: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000,
                               comm: name,
                               hasTTY: proc.kp_proc.p_flag & P_CONTROLT != 0 && proc.kp_eproc.e_tdev != -1)
    }

    /// Works for any process, including root-owned ones such as `login` between a terminal and its
    /// shell, which proc_pidinfo refuses.
    public static func info(_ pid: Int32) -> ProcessSnapshot? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var proc = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &proc, &size, nil, 0) == 0, size > 0, proc.kp_proc.p_pid == pid else { return nil }
        return snapshot(proc)
    }

    public static func path(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    public static func cwd(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        var path = info.pvi_cdir.vip_path
        let text = withUnsafeBytes(of: &path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return text.isEmpty ? nil : text
    }

    public static func arguments(_ pid: Int32) -> [String] {
        commandLine(pid).arguments
    }

    /// argv and environment from KERN_PROCARGS2 (environment as it was at exec time).
    public static func commandLine(_ pid: Int32) -> (arguments: [String], environment: [String: String]) {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return ([], [:]) }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return ([], [:]) }
        return parseProcArgs(Array(buffer.prefix(size)))
    }

    /// Layout: argc (Int32), executable path, NUL padding, argc strings, then environment strings.
    public static func parseProcArgs(_ buffer: [UInt8]) -> (arguments: [String], environment: [String: String]) {
        let size = buffer.count
        guard size > 4 else { return ([], [:]) }
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var index = 4
        while index < size, buffer[index] != 0 { index += 1 }  // executable path
        while index < size, buffer[index] == 0 { index += 1 }  // padding
        var strings: [String] = []
        while index < size {
            let begin = index
            while index < size, buffer[index] != 0 { index += 1 }
            if index == begin { break }  // an empty string ends the environment block
            strings.append(String(decoding: buffer[begin..<index], as: UTF8.self))
            index += 1
        }
        let count = min(Int(max(argc, 0)), strings.count)
        var environment: [String: String] = [:]
        for entry in strings.dropFirst(count) {
            guard let equals = entry.firstIndex(of: "=") else { continue }
            environment[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
        }
        return (Array(strings.prefix(count)), environment)
    }

    public static func isAlive(_ pid: Int32) -> Bool {
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }

    /// Ancestor chain starting at `pid` (inclusive), nearest first.
    public static func ancestors(of pid: Int32, limit: Int = 32) -> [ProcessSnapshot] {
        var chain: [ProcessSnapshot] = []
        var current = pid
        while chain.count < limit, current > 1, let info = info(current) {
            chain.append(info)
            current = info.ppid
        }
        return chain
    }
}

public enum AgentClassifier {
    /// Cheap pre-filter on the 16-byte kernel name before paying for path and argv lookups.
    public static func isCandidate(comm: String) -> Bool {
        if ["claude", "codex", "node", "bun"].contains(comm) { return true }
        // Claude Code also runs from versioned binaries such as ~/.local/share/claude/versions/2.1.302.
        return comm.first?.isNumber == true && comm.allSatisfy { $0.isNumber || $0 == "." }
    }

    public static func provider(comm: String, path: String?, arguments: [String]) -> Provider? {
        var names = [comm]
        if let path { names.append((path as NSString).lastPathComponent) }
        if ["node", "bun"].contains(comm), arguments.count > 1 {
            names.append((arguments[1] as NSString).lastPathComponent)
        }
        if names.contains(where: { $0 == "claude" || $0 == "claude.js" }) { return .claude }
        if let path, path.contains("/claude/versions/") { return .claude }
        if names.contains(where: { $0 == "codex" || $0 == "codex.js" }) { return .codex }
        return nil
    }

    /// Read the conversation ID from launch arguments, including Codex `resume UUID`.
    public static func sessionId(arguments: [String]) -> String? {
        if arguments.count > 2, (arguments[0] as NSString).lastPathComponent == "codex",
           arguments[1] == "resume", UUID(uuidString: arguments[2]) != nil {
            return arguments[2].lowercased()
        }
        for (index, argument) in arguments.enumerated() where index + 1 < arguments.count {
            if ["--session-id", "--resume", "-r"].contains(argument), UUID(uuidString: arguments[index + 1]) != nil {
                return arguments[index + 1].lowercased()
            }
        }
        return nil
    }

    /// Filters out daemons, attach clients and headless runs; only interactive sessions get pets.
    public static func isInteractive(arguments: [String]) -> Bool {
        let rest = arguments.dropFirst()
        if let sub = rest.first, ["daemon", "attach", "mcp", "exec", "doctor", "update", "bg-pty-host", "bg-spare"].contains(sub) {
            return false
        }
        return !rest.contains { ["-p", "--print", "--bg-pty-host", "--bg-spare"].contains($0) }
    }
}

/// Remembers which processes are agents, so a rescan only reads argv and paths for new processes.
public final class ClassificationCache: @unchecked Sendable {
    fileprivate struct Entry {
        var start: Double
        var provider: Provider?
        var cmux: CmuxLocation?
        var tmux: TmuxLocation?
        var launchSessionId: String?
    }

    fileprivate var entries: [Int32: Entry] = [:]

    public init() {}
}

public enum SessionScanner {
    /// Lists interactive claude/codex sessions owned by the current user.
    /// Not thread-safe per cache: call it from one serial queue.
    public static func scan(cache: ClassificationCache = ClassificationCache()) -> [AgentSession] {
        let table = ProcessTable.all()
        var found: [ProcessSnapshot: ClassificationCache.Entry] = [:]
        var seen = Set<Int32>()
        for process in table where process.hasTTY && AgentClassifier.isCandidate(comm: process.comm) {
            seen.insert(process.pid)
            if let cached = cache.entries[process.pid], cached.start == process.startTime {
                if cached.provider != nil { found[process] = cached }
                continue
            }
            let (arguments, environment) = ProcessTable.commandLine(process.pid)
            var entry = ClassificationCache.Entry(start: process.startTime, provider: nil)
            if let provider = AgentClassifier.provider(comm: process.comm, path: ProcessTable.path(process.pid), arguments: arguments),
               AgentClassifier.isInteractive(arguments: arguments) {
                entry.provider = provider
                entry.cmux = CmuxLocation.from(environment: environment)
                entry.tmux = TmuxLocation.from(environment: environment)
                entry.launchSessionId = AgentClassifier.sessionId(arguments: arguments)
                found[process] = entry
            }
            cache.entries[process.pid] = entry
        }
        cache.entries = cache.entries.filter { seen.contains($0.key) }
        // A wrapper (node → codex) shows up twice; keep the innermost, which is the one that runs hooks.
        let parents = Set(found.keys.map(\.ppid))
        return found.filter { !parents.contains($0.key.pid) }.compactMap { process, entry in
            guard let provider = entry.provider, let cwd = ProcessTable.cwd(process.pid) else { return nil }
            return AgentSession(provider: provider, pid: process.pid, startTime: process.startTime, cwd: cwd,
                                cmux: entry.cmux, launchSessionId: entry.launchSessionId, tmux: entry.tmux)
        }.sorted { $0.startTime < $1.startTime }
    }

    /// The nearest claude/codex ancestor of the calling process (used by the hook command).
    public static func agentAncestor(from pid: Int32 = getppid()) -> (pid: Int32, start: Double, provider: Provider)? {
        for process in ProcessTable.ancestors(of: pid) where AgentClassifier.isCandidate(comm: process.comm) {
            if let provider = AgentClassifier.provider(comm: process.comm, path: ProcessTable.path(process.pid),
                                                        arguments: ProcessTable.arguments(process.pid)) {
                return (process.pid, process.startTime, provider)
            }
        }
        return nil
    }
}

extension ProcessSnapshot: Hashable {}
