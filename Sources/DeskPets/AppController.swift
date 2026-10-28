import AppKit
import DeskPetsCore

/// Owns sessions, bindings and pet windows. Sessions come from a process scan every 2.5 s
/// plus hook records pushed through a directory watcher.
@MainActor
final class AppController: ObservableObject {
    nonisolated static var builtInCharacters: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("Characters", isDirectory: true)
    }

    let paths = AppPaths.current()
    let library: CharacterLibrary
    @Published private(set) var sessions: [AgentSession] = []
    @Published private(set) var characters: [CharacterInfo] = []
    @Published private(set) var config: AppConfig
    @Published private(set) var hooksInstalled: [Provider: Bool] = [:]

    private var processes: [AgentSession] = []
    private var records: [HookRecord] = []
    private var resolved: [UUID: String] = [:]
    private var pets: [UUID: PetWindowController] = [:]
    private var scanTimer: Timer?
    private var watcher: DirectoryWatcher?
    private var characterWatcher: DirectoryWatcher?
    private var pendingSave: DispatchWorkItem?
    private let scanQueue = DispatchQueue(label: "deskpets.scan", qos: .utility)
    private let scanCache = ClassificationCache()
    private let namer: SessionNamer
    private var hasScannedSessions = false
    private var names: [String: String] = [:]
    private var scanCount = 0
    private let homeWindow = PetHomeWindowController()
    private var homeLayout: PetHomeLayout?
    private var homePreview: PetHomeEdge?
    private var draggingPet: (id: UUID, origin: CGPoint)?
    private var movingHome = false

    init() {
        library = CharacterLibrary(builtInRoot: Self.builtInCharacters, customRoot: paths.characters)
        namer = SessionNamer(home: paths.home)
        config = AppConfig.load(from: paths.config)
        L.language = config.language
        try? FileManager.default.createDirectory(at: paths.sessions, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? FileManager.default.createDirectory(at: paths.characters, withIntermediateDirectories: true)
        characters = library.list()
        if config.migrateCharacterNames(using: characters) { save() }
        refreshHookStatus()
        homeWindow.onDrag = { [weak self] point, ended in self?.moveHome(to: point, ended: ended) }
        homeWindow.menuProvider = { [weak self] in self?.homeMenu() ?? NSMenu() }
    }

    func start() {
        watcher = DirectoryWatcher(url: paths.sessions) { [weak self] in self?.reloadRecords() }
        characterWatcher = DirectoryWatcher(url: paths.characters) { [weak self] in self?.reloadCharacters() }
        reloadRecords()
        scan()
        let timer = Timer(timeInterval: 2.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scan() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        scanTimer = timer
    }

    // MARK: - Sessions

    private func scan() {
        let directory = paths.sessions
        let cache = scanCache
        let namer = namer
        let records = records
        scanCount += 1
        let sweep = scanCount % 12 == 1  // about every 30 s
        scanQueue.async { [weak self] in
            let found = SessionScanner.scan(cache: cache)
            let names = namer.names(for: found, records: records)  // cached; cheap between refreshes
            if sweep { Self.removeStaleRecords(in: directory) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.hasScannedSessions = true
                self.processes = found
                self.names = names
                self.refresh()
            }
        }
    }

    private func reloadRecords() {
        records = HookEvents.readAll(from: paths.sessions)
        refresh()
    }

    /// Records of processes that no longer exist are deleted so the folder does not grow forever.
    nonisolated private static func removeStaleRecords(in directory: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let now = Date().timeIntervalSince1970
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let record = try? JSONDecoder().decode(HookRecord.self, from: data) else { continue }
            let dead = record.pid > 0 ? !ProcessTable.isAlive(record.pid) : now - record.updatedAt > 86_400
            if dead && now - record.updatedAt > 60 {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private func refresh() {
        guard hasScannedSessions else { return }
        let merged = SessionMerger.merge(processes, records: records).map { session in
            var session = session
            if let name = names[session.id] { session.title = name }
            return session
        }
        var updated = config
        resolved = BindingResolver.resolve(&updated, sessions: merged, characters: characters.map(\.name))
        if updated != config {
            config = updated
            saveSoon()
        }
        if merged != sessions {
            let old = Dictionary(sessions.map { ($0.id, $0.state) }, uniquingKeysWith: { a, _ in a })
            for session in merged where old[session.id] != session.state {
                Log.write("state \(session.displayName): \(old[session.id]?.rawValue ?? "new") → \(session.state.rawValue)")
            }
            sessions = merged
        }
        updatePets()
    }

    private func updatePets(moveAllHome: Bool = false) {
        prepareHome(moveAll: moveAllHome)
        let byId = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let largest = CGFloat(config.petSize) * (characters.map(\.displayScale).max() ?? 1)
        let dockScale = homeLayout.map { min(1, ($0.cellSize - 12) / largest) } ?? 1
        var alive = Set<UUID>()
        for binding in config.bindings {
            guard let sessionId = resolved[binding.id], let session = byId[sessionId],
                  let character = characters.first(where: { $0.name == binding.character }) else { continue }
            alive.insert(binding.id)
            let room = homeLayout.flatMap { config.home.slot(for: binding.id, capacity: $0.capacity) }
            let requestedSize = CGFloat(config.petSize) * character.displayScale
            let size = room == nil ? requestedSize : requestedSize * dockScale
            let pet = pets[binding.id] ?? makePet(for: binding, size: size)
            pet.update(session: session, character: character, size: size, animationDuration: config.animationDuration,
                       constrainToScreen: false)
            if draggingPet?.id != binding.id {
                if let room, let layout = homeLayout {
                    pet.setOrigin(layout.origin(for: room, petSize: size))
                } else {
                    if let x = binding.x, let y = binding.y { pet.setOrigin(CGPoint(x: x, y: y)) }
                    if let layout = homeLayout, !config.home.outside.contains(binding.id) {
                        pet.setOrigin(PetPlacement.outsideOrigin(for: pet.frame, avoiding: layout.frame,
                                                               screens: NSScreen.screens.map(\.visibleFrame)))
                    } else {
                        pet.keepOnScreen()
                    }
                }
            }
            if config.showPets { pet.show() } else { pet.hide() }
        }
        for (id, pet) in pets where !alive.contains(id) {
            if draggingPet?.id == id {
                draggingPet = nil
                homeWindow.highlight(nil)
            }
            pet.close()
            pets[id] = nil
        }
        renderHome()
    }

    private func makePet(for binding: PetBinding, size: CGFloat) -> PetWindowController {
        let origin: CGPoint
        if let x = binding.x, let y = binding.y {
            origin = CGPoint(x: x, y: y)
        } else {
            let frame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let occupiedWidth = pets.values.reduce(CGFloat.zero) { $0 + $1.frame.width + 16 }
            origin = CGPoint(x: frame.maxX - 40 - size - occupiedWidth, y: frame.minY + 24)
        }
        let pet = PetWindowController(bindingId: binding.id, origin: origin, size: size)
        pet.onMoved = { [weak self] id, point in self?.petMoved(id, to: point) }
        pet.onDragBegan = { [weak self] id, point in
            self?.draggingPet = (id, point)
            self?.renderHome()
        }
        pet.onDragEnded = { [weak self] id, point in self?.finishPetDrag(id, at: point) }
        pet.menuProvider = { [weak self] id in self?.contextMenu(for: id) ?? NSMenu() }
        pets[binding.id] = pet
        config.setPosition(binding.id, x: pet.frame.minX, y: pet.frame.minY)
        saveSoon()
        Log.write("pet shown for \(binding.provider.rawValue) \(binding.cwd) as \(binding.character)")
        return pet
    }

    private func contextMenu(for id: UUID) -> NSMenu {
        let menu = NSMenu()
        let characterMenu = NSMenu()
        let current = config.bindings.first { $0.id == id }?.character
        for character in characters {
            let item = ClosureMenuItem(title: character.displayName(in: L.language)) { [weak self] in self?.setCharacter(character.name, for: id) }
            item.state = character.name == current ? .on : .off
            characterMenu.addItem(item)
        }
        let characterItem = NSMenuItem(title: L.t("character.menu"), action: nil, keyEquivalent: "")
        characterItem.submenu = characterMenu
        menu.addItem(characterItem)
        menu.addItem(ClosureMenuItem(title: L.t("terminal.show")) { [weak self] in self?.pets[id]?.activateTerminal() })
        menu.addItem(ClosureMenuItem(title: L.t("settings.open")) {
            (NSApp.delegate as? AppDelegate)?.openManager()
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: L.t("binding.hide")) { [weak self] in self?.hidePet(id) })
        return menu
    }

    // MARK: - Bindings

    func repositionPets() {
        updatePets()
    }

    func binding(for session: AgentSession) -> PetBinding? {
        config.bindings.first { resolved[$0.id] == session.id }
    }

    /// 選擇角色並記住目錄偏好；nil 只隱藏目前工作階段。
    func setPet(_ character: String?, for session: AgentSession) {
        if let existing = binding(for: session) {
            if let character { setCharacter(character, for: existing.id) } else { hidePet(existing.id) }
            return
        }
        guard let character else { return }
        let binding = PetBinding(provider: session.provider, cwd: session.cwd, character: character,
                                 pid: session.pid, pidStart: session.startTime)
        config.bindings.append(binding)
        config.rememberCharacter(from: binding)
        save()
        refresh()
    }

    func setCharacter(_ name: String, for id: UUID) {
        guard let index = config.bindings.firstIndex(where: { $0.id == id }) else { return }
        config.bindings[index].character = name
        config.rememberCharacter(from: config.bindings[index])
        save()
        refresh()
    }

    func hidePet(_ id: UUID) {
        guard let index = config.bindings.firstIndex(where: { $0.id == id }) else { return }
        config.bindings[index].character = ""
        save()
        refresh()
    }

    private func petMoved(_ id: UUID, to origin: CGPoint) {
        if draggingPet?.id == id {
            homeWindow.highlight(homeLayout?.slot(at: NSEvent.mouseLocation))
            let preview = homeLayout?.expansionEdge(at: NSEvent.mouseLocation, home: config.home,
                                                   screens: NSScreen.screens.map(\.visibleFrame),
                                                   moving: id, active: Set(homeResidents))
            if preview != homePreview { renderHome() }
            return
        }
        config.setPosition(id, x: origin.x, y: origin.y)
        saveSoon()
    }

    // MARK: - Pet home

    private var homeResidents: [UUID] {
        config.bindings.filter { binding in
            resolved[binding.id] != nil && characters.contains { $0.name == binding.character }
        }.map(\.id)
    }

    private func prepareHome(moveAll: Bool) {
        guard config.home.enabled else {
            homeLayout = nil
            homePreview = nil
            return
        }
        var home = config.home
        let active = homeResidents
        let largest = CGFloat(config.petSize) * (characters.map(\.displayScale).max() ?? 1)
        let layout = home.arrange(active: active, petSize: largest, screens: NSScreen.screens.map(\.visibleFrame),
                                  moveAll: moveAll, constrain: !movingHome,
                                  allowResizing: draggingPet == nil && !movingHome)
        if home != config.home {
            config.home = home
            saveSoon()
        }
        homeLayout = layout
    }

    private func renderHome() {
        guard let layout = homeLayout else {
            homeWindow.hide()
            return
        }
        let occupied = Set(homeResidents.compactMap { config.home.slot(for: $0, capacity: layout.capacity) })
        homePreview = draggingPet.flatMap { drag in
            layout.expansionEdge(at: NSEvent.mouseLocation, home: config.home,
                                 screens: NSScreen.screens.map(\.visibleFrame), moving: drag.id, active: Set(homeResidents))
        }
        homeWindow.update(layout: layout, occupied: occupied, showsGrid: config.home.showsGrid || draggingPet != nil,
                          visible: config.showPets, preview: homePreview)
    }

    private func finishPetDrag(_ id: UUID, at point: CGPoint) {
        guard let drag = draggingPet, drag.id == id, let pet = pets[id] else { return }
        let screens = NSScreen.screens.map(\.visibleFrame)
        if let layout = homeLayout, let edge = layout.expansionEdge(at: point, home: config.home, screens: screens,
                                                                  moving: id, active: Set(homeResidents)) {
            homeLayout = config.home.expand(toward: edge, layout: layout, screens: screens) ?? layout
        }
        if let layout = homeLayout, let room = layout.slot(at: point) {
            if let displaced = config.home.place(id, in: room, active: Set(homeResidents), capacity: layout.capacity) {
                config.setPosition(displaced, x: drag.origin.x, y: drag.origin.y)
            }
        } else {
            if config.home.enabled { config.home.leave(id) }
            config.setPosition(id, x: pet.frame.minX, y: pet.frame.minY)
        }
        draggingPet = nil
        homeWindow.highlight(nil)
        updatePets()
        save()
    }

    private func moveHome(to point: CGPoint, ended: Bool) {
        movingHome = !ended
        config.home.x = point.x
        config.home.y = point.y
        updatePets()
        if ended { save() } else { saveSoon() }
    }

    func setHomeEnabled(_ enabled: Bool) {
        config.home.enabled = enabled
        updatePets()
        save()
    }

    func setHomeShowsGrid(_ show: Bool) {
        config.home.showsGrid = show
        renderHome()
        save()
    }

    func setHomeAutoAssign(_ enabled: Bool) {
        config.home.automaticallyAssign = enabled
        updatePets()
        save()
    }

    func setHomeSmartResize(_ enabled: Bool) {
        config.home.setSmartResize(enabled)
        updatePets()
        save()
    }

    func setHomeColumns(_ columns: Int) {
        config.home.setSize(columns: columns, rows: config.home.effectiveRows)
        updatePets()
        save()
    }

    func setHomeRows(_ rows: Int) {
        config.home.setSize(columns: config.home.effectiveColumns, rows: rows)
        updatePets()
        save()
    }

    func moveAllPetsHome() {
        updatePets(moveAllHome: true)
        save()
    }

    private func homeMenu() -> NSMenu {
        let menu = NSMenu()
        let grid = ClosureMenuItem(title: L.t("home.showGrid")) { [weak self] in
            guard let self else { return }
            self.setHomeShowsGrid(!self.config.home.showsGrid)
        }
        grid.state = config.home.showsGrid ? .on : .off
        menu.addItem(grid)
        menu.addItem(ClosureMenuItem(title: L.t("home.moveAll")) { [weak self] in self?.moveAllPetsHome() })
        menu.addItem(ClosureMenuItem(title: L.t("settings.open")) {
            (NSApp.delegate as? AppDelegate)?.openManager()
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: L.t("home.disable")) { [weak self] in self?.setHomeEnabled(false) })
        return menu
    }

    func setShowPets(_ show: Bool) {
        config.showPets = show
        save()
        Log.write("show pets: \(show)")
        refresh()
    }

    func setPetSize(_ size: Int) {
        config.petSize = size
        save()
        refresh()
    }

    func setAnimationDuration(_ duration: Double?) {
        if let duration, !AppConfig.animationDurationRange.contains(duration) { return }
        config.animationDuration = duration
        save()
        updatePets()
    }

    func setLanguage(_ language: AppLanguage) {
        L.language = language
        config.language = language
        save()
        updatePets()
        (NSApp.delegate as? AppDelegate)?.updateLanguage()
    }

    func characterName(_ name: String) -> String {
        characters.first { $0.name == name }?.displayName(in: L.language) ?? name
    }

    // MARK: - Characters

    private func reloadCharacters() {
        let list = library.list()
        guard list != characters else { return }
        characters = list
        refresh()
    }

    func importCharacter(name: String, idle: URL, working: URL?, waiting: URL?) throws {
        try library.importCharacter(name: name, idle: idle, working: working, waiting: waiting)
        characters = library.list()
    }

    func deleteCharacter(_ character: CharacterInfo) throws {
        try library.delete(character)
        characters = library.list()
        refresh()
    }

    // MARK: - Hooks

    var hookExecutable: String {
        Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("deskpets-hook").path
    }

    func installHooks() throws -> [HookInstaller.Change] {
        defer { refreshHookStatus() }
        return try HookInstaller(paths: paths, hookExecutable: hookExecutable).install()
    }

    func uninstallHooks() throws -> [HookInstaller.Change] {
        defer { refreshHookStatus() }
        return try HookInstaller(paths: paths, hookExecutable: hookExecutable).uninstall()
    }

    func refreshHookStatus() {
        let installer = HookInstaller(paths: paths, hookExecutable: hookExecutable)
        hooksInstalled = Dictionary(uniqueKeysWithValues: Provider.allCases.map { ($0, installer.isInstalled($0)) })
    }

    // MARK: - Persistence

    private func save() {
        pendingSave?.cancel()
        pendingSave = nil
        do {
            try config.save(to: paths.config)
        } catch {
            Log.write("could not save config: \(error.localizedDescription)")
        }
    }

    private func saveSoon() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.save() }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
}

/// Fires `onChange` (coalesced) whenever files are added, replaced or removed in a directory.
final class DirectoryWatcher {
    private let source: DispatchSourceFileSystemObject

    init?(url: URL, onChange: @escaping @MainActor () -> Void) {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete],
                                                           queue: .main)
        var pending = false
        source.setEventHandler {
            guard !pending else { return }
            pending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                pending = false
                MainActor.assumeIsolated { onChange() }
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
    }

    deinit {
        source.cancel()
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func run() {
        handler()
    }
}
