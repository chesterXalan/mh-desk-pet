import AppKit
import DeskPetsCore
import Foundation
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let controller = AppController()
    private var statusItem: NSStatusItem!
    private var showItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var manageWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let id = Bundle.main.bundleIdentifier, NSRunningApplication.runningApplications(withBundleIdentifier: id).count > 1 {
            Log.write("another instance is running; quitting")
            NSApp.terminate(nil)
            return
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "MH Desk Pets")
        image?.isTemplate = true
        statusItem.button?.image = image

        let menu = NSMenu()
        menu.delegate = self
        showItem = menu.addItem(withTitle: L.t("pets.show"), action: #selector(toggleShow), keyEquivalent: "")
        menu.addItem(withTitle: L.t("menu.manage"), action: #selector(openManager), keyEquivalent: ",")
        loginItem = menu.addItem(withTitle: L.t("menu.login"), action: #selector(toggleLogin), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: L.t("menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) {
            item.target = self
        }
        statusItem.menu = menu
        let launched = ProcessTable.info(getpid())?.startTime ?? Date().timeIntervalSince1970
        Log.write(String(format: "menu bar item ready, %.0f ms after process start", (Date().timeIntervalSince1970 - launched) * 1000))
        controller.start()
        // `deskpets-hook pets show|hide` flips the same switch as the menu item, for scripts.
        DistributedNotificationCenter.default().addObserver(forName: PetsSwitch.name, object: nil, queue: .main) { [weak self] note in
            let show = note.object as? String != PetsSwitch.hide
            MainActor.assumeIsolated { self?.controller.setShowPets(show) }
        }
    }

    /// Opening the app again (Finder, Spotlight, `open`) while it runs shows the manager.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openManager()
        return false
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        controller.repositionPets()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        showItem.state = controller.config.showPets ? .on : .off
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    func updateLanguage() {
        guard let menu = statusItem?.menu else { return }
        for item in menu.items {
            switch item.action {
            case #selector(toggleShow): item.title = L.t("pets.show")
            case #selector(openManager): item.title = L.t("menu.manage")
            case #selector(toggleLogin): item.title = L.t("menu.login")
            case #selector(NSApplication.terminate(_:)): item.title = L.t("menu.quit")
            default: break
            }
        }
        manageWindow?.title = L.t("app.title")
    }

    @objc private func toggleShow() {
        controller.setShowPets(!controller.config.showPets)
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    @objc func openManager() {
        if manageWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: ManageView().environmentObject(controller)))
            window.title = L.t("app.title")
            window.setContentSize(NSSize(width: 720, height: 460))
            window.isReleasedWhenClosed = false
            window.level = .normal
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            window.center()
            manageWindow = window
        }
        // 等選單收起後再取回焦點，只在使用者開啟設定時帶到前景。
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.manageWindow else { return }
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.setFrameOrigin(PetPlacement.visibleOrigin(for: window.frame, screens: NSScreen.screens.map(\.visibleFrame)))
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }
}

enum Log {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    static func write(_ message: String) {
        FileHandle.standardError.write(Data("[\(formatter.string(from: Date()))] \(message)\n".utf8))
    }
}
