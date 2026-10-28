import AppKit
import DeskPetsCore
import SwiftUI
import UniformTypeIdentifiers

struct ManageView: View {
    @EnvironmentObject private var app: AppController

    var body: some View {
        TabView {
            SettingsTab().tabItem { Text(L.t("settings.title")) }
            HomeTab().tabItem { Text(L.t("home.title")) }
            SessionsTab().tabItem { Text(L.t("sessions.title")) }
            CharactersTab().tabItem { Text(L.t("characters.title")) }
            HooksTab().tabItem { Text(L.t("hooks.title")) }
        }
        .environment(\.locale, Locale(identifier: app.config.language.resolved().rawValue))
        .padding()
        .frame(minWidth: 640, minHeight: 400)
    }
}

private struct SettingsTab: View {
    @EnvironmentObject private var app: AppController

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Picker(L.t("language.label"), selection: Binding(
                get: { app.config.language }, set: { app.setLanguage($0) })) {
                ForEach(AppLanguage.allCases, id: \.self) { language in
                    Text(L.languageName(language)).tag(language)
                }
            }
            Toggle(L.t("pets.show"), isOn: Binding(
                get: { app.config.showPets }, set: { app.setShowPets($0) }))
            HStack {
                Text(L.t("pets.size"))
                Spacer()
                SizePicker()
            }
            Divider()
            Toggle(L.t("animation.custom"), isOn: Binding(
                get: { app.config.animationDuration != nil },
                set: { app.setAnimationDuration($0 ? 1.2 : nil) }))
            if let duration = app.config.animationDuration {
                HStack(spacing: 12) {
                    Text(L.t("animation.faster"))
                    Slider(value: Binding(get: { app.config.animationDuration ?? 1.2 },
                                          set: { app.setAnimationDuration($0) }),
                           in: AppConfig.animationDurationRange, step: 0.1)
                        .accessibilityLabel(L.t("animation.duration"))
                    Text(L.t("animation.slower"))
                    Text(String(format: L.t("animation.loop"), duration))
                        .monospacedDigit().frame(width: 105, alignment: .trailing)
                }
                HStack {
                    ForEach([1.2, 1.6, 2.0, 2.4], id: \.self) { value in
                        Button(String(format: L.t("animation.seconds"), value)) {
                            app.setAnimationDuration(value)
                        }
                    }
                }
            }
            Text(L.t("animation.help"))
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(12)
    }
}

private struct HomeTab: View {
    @EnvironmentObject private var app: AppController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(L.t("home.enable"), isOn: Binding(
                get: { app.config.home.enabled }, set: { app.setHomeEnabled($0) }))
            VStack(alignment: .leading, spacing: 12) {
                Toggle(L.t("home.showGrid"), isOn: Binding(
                    get: { app.config.home.showsGrid }, set: { app.setHomeShowsGrid($0) }))
                Toggle(L.t("home.autoAssign"), isOn: Binding(
                    get: { app.config.home.automaticallyAssign }, set: { app.setHomeAutoAssign($0) }))
                Toggle(L.t("home.smartResize"), isOn: Binding(
                    get: { app.config.home.smartResize }, set: { app.setHomeSmartResize($0) }))
                    .help(L.t("home.smartHelp"))
                HStack(spacing: 12) {
                    Picker(L.t("home.columns"), selection: Binding(
                        get: { app.config.home.effectiveColumns }, set: { app.setHomeColumns($0) })) {
                        ForEach(1...8, id: \.self) { Text(String($0)).tag($0) }
                    }
                    Text("×").foregroundStyle(.secondary)
                    Picker(L.t("home.rows"), selection: Binding(
                        get: { app.config.home.effectiveRows }, set: { app.setHomeRows($0) })) {
                        ForEach(1...8, id: \.self) { Text(String($0)).tag($0) }
                    }
                    Text(L.format("home.capacity", app.config.home.effectiveColumns * app.config.home.effectiveRows))
                        .foregroundStyle(.secondary)
                }
                .fixedSize()
                HStack(spacing: 16) {
                    Button(L.t("home.moveAll")) { app.moveAllPetsHome() }
                    Menu(L.t("home.moveToDisplay")) {
                        ForEach(Array(NSScreen.screens.enumerated()), id: \.offset) { index, screen in
                            Button("\(index + 1) · \(screen.localizedName)") { app.moveHomeToDisplay(screen) }
                        }
                    }
                    .fixedSize()
                }
            }
            .disabled(!app.config.home.enabled)
            Divider()
            Text(L.t("home.help"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
    }
}

// MARK: - Sessions

private struct SessionsTab: View {
    @EnvironmentObject private var app: AppController
    @StateObject private var ui = SessionsUI()

    private var rows: [SessionTableRow] {
        app.sessions.map { SessionTableRow(session: $0) }.sorted(using: ui.sortOrder.prefix(1))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Table(rows, sortOrder: $ui.sortOrder) {
                TableColumn(L.t("session.label"), value: \.name) { row in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: row.name)
                        if row.session.title != nil {
                            Text(verbatim: row.session.location).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .help(row.session.cwd)
                }
                TableColumn("CLI", value: \.cli) { row in Text(row.cli) }
                    .width(60)
                TableColumn(L.t("state.label"), value: \.statePriority) { row in StateLabel(state: row.session.state) }
                    .width(110)
                TableColumn(L.t("pet.label")) { row in
                    Picker("", selection: Binding(
                        get: { app.binding(for: row.session)?.character ?? "" },
                        set: { app.setPet($0.isEmpty ? nil : $0, for: row.session) })) {
                        Text(L.t("binding.none")).tag("")
                        ForEach(app.characters) { Text($0.displayName(in: L.language)).tag($0.name) }
                    }
                    .labelsHidden()
                }
                .width(150)
            }
            HStack {
                Toggle(L.t("pets.show"), isOn: Binding(get: { app.config.showPets }, set: { app.setShowPets($0) }))
                Spacer()
                SizePicker()
            }
        }
    }
}

private struct StateLabel: View {
    let state: PetState

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(name)
        }
    }

    private var color: Color {
        switch state {
        case .working: return .green
        case .waiting: return .orange
        case .idle: return .gray
        case .unknown, .exited: return .gray.opacity(0.3)
        }
    }

    private var name: String {
        switch state {
        case .working: return L.t("state.working")
        case .waiting: return L.t("state.waiting")
        case .idle: return L.t("state.idle")
        case .unknown, .exited: return L.t("state.unknown")
        }
    }
}

private struct SizePicker: View {
    @EnvironmentObject private var app: AppController

    var body: some View {
        Picker(L.t("size.label"), selection: Binding(get: { app.config.petSize }, set: { app.setPetSize($0) })) {
            ForEach(AppConfig.sizes, id: \.self) { Text("\($0) px").tag($0) }
        }
        .pickerStyle(.segmented)
        .fixedSize()
    }
}

// MARK: - Characters

private struct CharactersTab: View {
    @EnvironmentObject private var app: AppController
    @StateObject private var ui = CharactersUI()

    private var rows: [CharacterTableRow] {
        let rows = app.characters.map { CharacterTableRow(character: $0, name: $0.displayName(in: L.language)) }
            .sorted(using: ui.sortOrder)
        guard ui.sortOrder.first?.keyPath == \CharacterTableRow.emID else { return rows }
        return rows.filter { $0.character.emID != nil } + rows.filter { $0.character.emID == nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Table(rows, sortOrder: $ui.sortOrder) {
                TableColumn("") { row in
                    GIFThumbnail(url: row.character.gif(for: .idle))
                        .padding(.vertical, 2)
                }
                .width(48)
                TableColumn(L.t("character.emID"), value: \.emID) { row in
                    Text(row.character.emID.map { String(format: "em%03d", $0) } ?? "—")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                .width(90)
                TableColumn(L.t("character.name"), value: \.name) { row in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading) {
                            Text(row.name).lineLimit(1).help(row.name)
                            Text(row.character.builtIn ? L.t("character.builtIn") : row.character.directory.path)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                        if !row.character.builtIn {
                            Button(L.t("action.delete")) { ui.pendingDelete = row.character }
                        }
                    }
                }
            }
            HStack {
                Button(L.t("character.add")) { ui.adding = true }
                Spacer()
                SizePicker()
            }
        }
        .sheet(isPresented: $ui.adding) { AddCharacterSheet() }
        .confirmationDialog(L.t("character.deleteQuestion"), isPresented: Binding(
            get: { ui.pendingDelete != nil }, set: { if !$0 { ui.pendingDelete = nil } }), presenting: ui.pendingDelete) { character in
            Button(L.format("character.deleteNamed", character.displayName(in: L.language)), role: .destructive) {
                do { try app.deleteCharacter(character) } catch { ui.error = L.error(error) }
            }
        }
        .alert(ui.error ?? "", isPresented: Binding(get: { ui.error != nil }, set: { if !$0 { ui.error = nil } })) {}
    }
}

private struct GIFThumbnail: View {
    let url: URL

    var body: some View {
        Group {
            if let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().interpolation(.none).aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "questionmark.square.dashed")
            }
        }
        .frame(width: 40, height: 40)
    }
}

private struct AddCharacterSheet: View {
    @EnvironmentObject private var app: AppController
    @Environment(\.dismiss) private var dismiss
    @StateObject private var form = CharacterForm()

    private static var slots: [(String, String)] {
        [("idle", L.t("character.idle")),
         ("working", L.t("character.working")),
         ("waiting", L.t("character.waiting"))]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L.t("character.new")).font(.headline)
            TextField(L.t("character.name"), text: $form.name)
            ForEach(Self.slots, id: \.0) { key, title in
                HStack {
                    Text(title).frame(width: 140, alignment: .leading)
                    Text(form.files[key]?.lastPathComponent ?? "—")
                        .foregroundStyle(form.files[key] == nil ? .secondary : .primary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if form.files[key] != nil {
                        Button(L.t("action.clear")) { form.files[key] = nil }
                    }
                    Button(L.t("action.choose")) { choose(key) }
                }
            }
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4]))
                .foregroundStyle(.secondary)
                .frame(height: 60)
                .overlay(Text(L.t("character.drop"))
                    .font(.caption).foregroundStyle(.secondary))
                .dropDestination(for: URL.self) { urls, _ in
                    assign(urls)
                    return true
                }
            if let error = form.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(L.t("action.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L.t("action.add")) { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(form.name.trimmingCharacters(in: .whitespaces).isEmpty || form.files["idle"] == nil)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func choose(_ key: String) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.gif]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { form.files[key] = url }
    }

    private func assign(_ urls: [URL]) {
        let gifs = urls.filter { $0.pathExtension.lowercased() == "gif" }
        var unnamed: [URL] = []
        for url in gifs {
            let stem = url.deletingPathExtension().lastPathComponent.lowercased()
            if ["idle", "working", "waiting"].contains(stem) { form.files[stem] = url } else { unnamed.append(url) }
        }
        for url in unnamed {
            if let free = ["idle", "working", "waiting"].first(where: { form.files[$0] == nil }) { form.files[free] = url }
        }
        if form.name.isEmpty, let first = gifs.first {
            form.name = first.deletingLastPathComponent().lastPathComponent
        }
    }

    private func add() {
        guard let idle = form.files["idle"] else { return }
        do {
            try app.importCharacter(name: form.name, idle: idle, working: form.files["working"], waiting: form.files["waiting"])
            dismiss()
        } catch {
            form.error = L.error(error)
        }
    }
}

// MARK: - Hooks

private struct HooksTab: View {
    @EnvironmentObject private var app: AppController
    @StateObject private var ui = MessageUI()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("Claude Code").bold()
                    Text(app.paths.claudeSettings.path).font(.caption.monospaced())
                    Text(status(.claude))
                }
                GridRow {
                    Text("Codex").bold()
                    Text(app.paths.codexHooks.path).font(.caption.monospaced())
                    Text(status(.codex))
                }
            }
            HStack {
                Button(L.t("hooks.install")) { run { try app.installHooks() } }
                Button(L.t("hooks.remove")) { run { try app.uninstallHooks() } }
            }
            if !ui.message.isEmpty {
                Text(ui.message).font(.caption.monospaced()).textSelection(.enabled)
            }
            Divider()
            Text(L.t("hooks.help"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(L.t("hooks.backupHelp"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { app.refreshHookStatus() }
    }

    private func status(_ provider: Provider) -> String {
        app.hooksInstalled[provider] == true ? L.t("hooks.installed") : L.t("hooks.notInstalled")
    }

    private func run(_ action: () throws -> [HookInstaller.Change]) {
        do {
            let changes = try action()
            ui.message = changes.isEmpty
                ? L.t("hooks.noChanges")
                : changes.map { "✓ \($0.file.path)" + ($0.backup.map { "\n   " + L.format("hooks.backup", $0.lastPathComponent) } ?? "") }.joined(separator: "\n")
        } catch {
            ui.message = L.error(error)
        }
    }
}

private struct SessionTableRow: Identifiable {
    let session: AgentSession

    var id: String { session.id }
    var name: String { session.displayName }
    var cli: String { session.provider.rawValue }
    var statePriority: Int {
        switch session.state {
        case .waiting: return 0
        case .working: return 1
        case .idle: return 2
        case .unknown: return 3
        case .exited: return 4
        }
    }
}

private struct CharacterTableRow: Identifiable {
    let character: CharacterInfo
    let name: String

    var id: String { character.id }
    var emID: Int { character.emID ?? Int.max }
}

// SwiftUI's @State is a macro the Command Line Tools cannot expand, so view state lives in small objects.
private final class SessionsUI: ObservableObject {
    @Published var sortOrder: [KeyPathComparator<SessionTableRow>] = []
}

private final class CharactersUI: ObservableObject {
    @Published var sortOrder = [KeyPathComparator(\CharacterTableRow.emID)]
    @Published var adding = false
    @Published var pendingDelete: CharacterInfo?
    @Published var error: String?
}

private final class CharacterForm: ObservableObject {
    @Published var name = ""
    @Published var files: [String: URL] = [:]
    @Published var error: String?
}

private final class MessageUI: ObservableObject {
    @Published var message = ""
}
