import AppKit
import DeskPetsCore

/// Focus the session's terminal and select its tmux pane or cmux tab.
@MainActor
enum TerminalFocus {
    static func focus(_ session: AgentSession, completion: (@Sendable (Bool) -> Void)? = nil) {
        if let location = session.tmux {
            focusTmux(location, completion: completion)
            return
        }
        guard let app = hostApp(of: session.pid) else {
            NSSound.beep()
            completion?(false)
            return
        }
        if app.bundleIdentifier == GhosttyControl.bundleIdentifier {
            do {
                try GhosttyAutomation.focus(directory: session.cwd, title: session.title)
                bringToFront(app)
                completion?(true)
            } catch {
                report(error, completion: completion)
            }
            return
        }
        guard let location = session.cmux, app.bundleIdentifier == CmuxControl.bundleIdentifier else {
            bringToFront(app)
            completion?(true)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let switched = CmuxControl.focus(location)
            DispatchQueue.main.async {
                bringToFront(app)
                completion?(switched)
            }
        }
    }

    private static func focusTmux(_ location: TmuxLocation, completion: (@Sendable (Bool) -> Void)?) {
        Task {
            let clients = await Task.detached { TmuxControl.clients(for: location) }.value
            guard let (client, app) = clients.lazy.compactMap({ client in
                hostApp(of: client.pid).map { (client, $0) }
            }).first else {
                NSSound.beep()
                completion?(false)
                return
            }
            do {
                var terminalID: UUID?
                if app.bundleIdentifier == GhosttyControl.bundleIdentifier {
                    let (directory, title) = await Task.detached {
                        (ProcessTable.cwd(client.pid), TmuxControl.terminalTitle(for: location, client: client))
                    }.value
                    guard let directory else { throw GhosttyFocusError.notFound }
                    // Switching panes changes the title, so capture the stable outer Ghostty tab ID first.
                    terminalID = try GhosttyAutomation.target(directory: directory, title: title).id
                }
                let switched = await Task.detached { TmuxControl.focus(location, client: client) }.value
                guard switched else {
                    NSSound.beep()
                    completion?(false)
                    return
                }
                if let terminalID { try GhosttyAutomation.focus(terminalID: terminalID) }
                bringToFront(app)
                completion?(true)
            } catch {
                report(error, completion: completion)
            }
        }
    }

    private static func report(_ error: Error, completion: (@Sendable (Bool) -> Void)?) {
        if completion == nil {
            let alert = NSAlert()
            alert.messageText = L.t("error.terminalFocus")
            alert.informativeText = L.error(error)
            NSApplication.shared.activate()
            alert.runModal()
        }
        completion?(false)
    }

    /// The nearest ancestor that is a regular (Dock) app, e.g. cmux for claude → zsh → login → cmux.
    static func hostApp(of pid: Int32) -> NSRunningApplication? {
        for process in ProcessTable.ancestors(of: pid) {
            if let app = NSRunningApplication(processIdentifier: process.pid), app.activationPolicy == .regular {
                return app
            }
        }
        return nil
    }

    private static func bringToFront(_ app: NSRunningApplication) {
        app.activate()
        // activate() can be ignored when Desk Pets itself is not active; Launch Services is not.
        if let url = app.bundleURL {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
    }
}
