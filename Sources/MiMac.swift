import SwiftUI
import AppKit
import QuickLookUI
import QuickLookThumbnailing

struct Sample: Decodable { let t: Double; let org: String?; let u: Usage; let resets: [String: Double]? }
struct Usage: Decodable {
    let fh: Double?; let sd: Double?; let extra: [String: Double]
    struct Key: CodingKey { let stringValue: String; var intValue: Int? { nil }; init?(stringValue: String) { self.stringValue = stringValue }; init?(intValue: Int) { return nil } }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        fh = try? c.decode(Double.self, forKey: Key(stringValue: "fh")!)
        sd = try? c.decode(Double.self, forKey: Key(stringValue: "sd")!)
        var more: [String: Double] = [:]
        for key in c.allKeys where key.stringValue != "fh" && key.stringValue != "sd" {
            if let value = try? c.decode(Double.self, forKey: key), (0...100).contains(value) { more[key.stringValue] = value }
        }
        extra = more
    }
}
struct History: Decodable { let samples: [Sample] }

struct CodexWindow: Decodable {
    let used_percent: Double
    let window_minutes: Int
    let resets_at: Double?
}
struct CodexLimits: Decodable {
    let limit_id: String?
    let primary: CodexWindow?
    let secondary: CodexWindow?
}
struct CodexEvent: Decodable {
    struct Payload: Decodable { let type: String; let rate_limits: CodexLimits? }
    let timestamp: String
    let type: String
    let payload: Payload
}
struct CodexSample {
    let date: Date
    let limits: CodexLimits
    var windows: [CodexWindow] { [limits.primary, limits.secondary].compactMap { $0 } }
}

// Read only quota events; conversation contents are never retained or displayed.
func readCodexSample() -> CodexSample? {
    let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return nil }
    var files: [(URL, Date)] = []
    for case let url as URL in enumerator where url.pathExtension == "jsonl" {
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        files.append((url, date))
    }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let standard = ISO8601DateFormatter()
    var latest: CodexSample?
    for (url, _) in files.sorted(by: { $0.1 > $1.1 }).prefix(20) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { continue }
        let offset = end > 2_097_152 ? end - 2_097_152 : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else { continue }
        for line in text.split(separator: "\n").reversed() {
            guard line.contains("\"token_count\""), line.contains("\"rate_limits\""),
                  let event = try? JSONDecoder().decode(CodexEvent.self, from: Data(line.utf8)),
                  event.type == "event_msg", event.payload.type == "token_count",
                  let limits = event.payload.rate_limits, limits.limit_id == nil || limits.limit_id == "codex",
                  limits.primary != nil || limits.secondary != nil,
                  let date = fractional.date(from: event.timestamp) ?? standard.date(from: event.timestamp) else { continue }
            if latest == nil || date > latest!.date { latest = CodexSample(date: date, limits: limits) }
            break
        }
    }
    return latest
}

final class Monitor: ObservableObject {
    let history = UsageHistoryStore()
    @Published var sample: Sample?
    @Published var codex: CodexSample?
    private var readingCodex = false
    var claudeIsStale: Bool {
        guard let sample else { return true }
        return updated.timeIntervalSince1970 - sample.t / 1000 > 900
    }
    @Published var error: String?
    @Published var disk = "—"
    @Published var updated = Date()
    var timer: Timer?
    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.refresh() }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }
    func refresh() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let desktopFile = home.appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json")
        let bridgeFile = home.appendingPathComponent("Library/Application Support/MiMac/claude-code-usage.json")
        var candidates: [Sample] = []
        let webFile = home.appendingPathComponent("Library/Application Support/MiMac/claude-web-usage.json")
        if let data = try? Data(contentsOf: webFile), let value = try? JSONDecoder().decode(Sample.self, from: data) { candidates.append(value) }
        if let data = try? Data(contentsOf: desktopFile), let values = try? JSONDecoder().decode(History.self, from: data), let latest = values.samples.max(by: { $0.t < $1.t }) { candidates.append(latest) }
        if let data = try? Data(contentsOf: bridgeFile), let value = try? JSONDecoder().decode(Sample.self, from: data) { candidates.append(value) }
        if let latest = candidates.max(by: { $0.t < $1.t }) {
            sample = latest; self.history.claude(latest); error = nil
        } else {
            sample = nil; error = "Sin datos de Claude Code"
        }
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
           let free = attrs[.systemFreeSize] as? NSNumber, let total = attrs[.systemSize] as? NSNumber {
            disk = "\(ByteCountFormatter.string(fromByteCount: free.int64Value, countStyle: .file)) libres de \(ByteCountFormatter.string(fromByteCount: total.int64Value, countStyle: .file))"
        }
        updated = Date()
        if !readingCodex {
            readingCodex = true
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let result = readCodexSample()
                DispatchQueue.main.async {
                    self?.codex = result
                    if let result { self?.history.codex(result) }
                    self?.readingCodex = false
                }
            }
        }
    }
}

struct ContentView: View {
    @ObservedObject var monitor: Monitor
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Image(systemName: "desktopcomputer").font(.system(size: 34)).foregroundStyle(.blue)
                    VStack(alignment: .leading) {
                        Text("Mi Mac").font(.largeTitle.bold())
                        Text("Tu computadora, de un vistazo").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(action: monitor.refresh) { Label("Actualizar", systemImage: "arrow.clockwise") }
                }
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Text("Claude").font(.title2.bold())
                        Spacer()
                        Text("Uso del plan").font(.caption).foregroundStyle(.secondary)
                    }
                    if let sample = monitor.sample {
                        usageRow("Sesión actual", value: sample.u.fh)
                        usageRow("Semana · todos los modelos", value: sample.u.sd)
                        let date = Date(timeIntervalSince1970: sample.t / 1000)
                        Label("Último registro: \(date.formatted(date: .abbreviated, time: .shortened))", systemImage: "clock").font(.caption).foregroundStyle(.secondary)
                        if monitor.updated.timeIntervalSince(date) > 900 {
                            Label("El registro tiene más de 15 minutos. Abrí Claude para actualizar el uso.", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                        }
                    } else {
                        Text(monitor.error ?? "Sin datos disponibles").foregroundStyle(.secondary)
                    }
                    Text("Fuente: historial local de Claude. Se revisa cada 30 segundos; los valores cambian cuando Claude guarda un nuevo registro. Corresponde a la última cuenta registrada en este Mac.").font(.caption).foregroundStyle(.secondary)
                    Divider()
                    HStack(alignment: .center) {
                        Text("El historial no informa cuándo se restablecen los límites.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Ver límites en Claude") { NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!) }
                    }
                }.padding(24).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 18))
                VStack(alignment: .leading, spacing: 14) {
                    Text("Tu computadora").font(.title2.bold())
                    info("Nombre", value: Host.current().localizedName ?? "Mac")
                    info("Sistema", value: "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
                    info("Memoria instalada", value: ByteCountFormatter.string(fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory), countStyle: .memory))
                    info("Procesadores lógicos", value: "\(ProcessInfo.processInfo.processorCount)")
                    info("Disco del usuario", value: monitor.disk)
                }.padding(24).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 18))
                Text("Los datos se leen en este Mac. La app no envía información ni accede a credenciales.").font(.caption).foregroundStyle(.secondary)
            }.padding(28)
        }.frame(minWidth: 620, minHeight: 650)
    }
    func usageRow(_ title: String, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                if let value = value, value.isFinite, (0...100).contains(value) {
                    Text("\(Int(value.rounded()))% usado").bold().monospacedDigit()
                } else { Text("Sin datos").foregroundStyle(.secondary) }
            }
            if let value = value, value.isFinite, (0...100).contains(value) {
                ProgressView(value: value, total: 100).tint(value >= 90 ? .orange : .blue)
                Text("\(Int((100 - value).rounded()))% disponible").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    func info(_ title: String, value: String) -> some View {
        HStack { Text(title).foregroundStyle(.secondary); Spacer(); Text(value).multilineTextAlignment(.trailing) }
    }
}

final class FileShelf: ObservableObject {
    private let defaults: UserDefaults
    @Published var files: [URL]
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.files = (defaults.stringArray(forKey: "shelfFiles") ?? []).map { URL(fileURLWithPath: $0) }
    }
    func add(_ urls: [URL]) {
        for url in urls where url.isFileURL && FileManager.default.fileExists(atPath: url.path) {
            let normalized = url.standardizedFileURL
            if !files.contains(normalized) { files.append(normalized) }
        }
        save()
    }
    func remove(_ url: URL) { files.removeAll { $0 == url }; save() }
    func save() { defaults.set(files.map(\.path), forKey: "shelfFiles") }
    func copy(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([url as NSURL])
    }
}

final class ShelfHostingView: NSHostingView<NotchView> {
    weak var controller: NotchController?
    init(controller: NotchController, top: CGFloat, screenID: String) {
        self.controller = controller
        super.init(rootView: NotchView(monitor: controller.monitor, controller: controller, screenTop: top, screenIdentifier: screenID))
        registerForDraggedTypes([.fileURL])
    }
    required init(rootView: NotchView) {
        self.controller = rootView.controller
        super.init(rootView: rootView)
        registerForDraggedTypes([.fileURL])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    func urls(_ sender: NSDraggingInfo) -> [URL] {
        (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !urls(sender).isEmpty else { return [] }
        if controller?.draggingFile == false { controller?.tabBeforeDrag = controller?.selectedTab }
        controller?.draggingFile = true
        controller?.showingFiles = true
        controller?.expandedScreens.insert(rootView.screenIdentifier)
        controller?.layout()
        return .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { urls(sender).isEmpty ? [] : .copy }
    override func draggingExited(_ sender: NSDraggingInfo?) {
        controller?.draggingFile = false
        if let previous = controller?.tabBeforeDrag { controller?.selectedTab = previous }
        controller?.tabBeforeDrag = nil
    }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { !urls(sender).isEmpty }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let files = urls(sender)
        guard !files.isEmpty else { return false }
        controller?.shelf.add(files)
        controller?.draggingFile = false
        return true
    }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { controller?.draggingFile = false }
}

enum NotchTab: String, CaseIterable {
    case agents, files, mac, music, brew, clipboard, audio, options
    var title: String {
        switch self {
        case .agents: return "IA"
        case .files: return "Archivos"
        case .mac: return "Mac"
        case .music: return "Reproductor"
        case .brew: return "Brew"
        case .clipboard: return "Copias"
        case .audio: return "Audio"
        case .options: return "Opciones"
        }
    }
    var icon: String {
        switch self {
        case .agents: return "sparkles"
        case .files: return "tray"
        case .mac: return "desktopcomputer"
        case .music: return "music.note"
        case .brew: return "mug"
        case .clipboard: return "doc.on.clipboard"
        case .audio: return "speaker.wave.2"
        case .options: return "gearshape"
        }
    }
}
final class NotchPanel: NSPanel { override var canBecomeKey: Bool { true } }

final class NotchController: NSObject, NSApplicationDelegate, ObservableObject {
    let monitor = Monitor()
    let claudeSession = ClaudeSession()
    let shelf = FileShelf()
    @Published var draggingFile = false
    let macStatus = MacStatus()
    lazy var catRunner = CatRunner(mac: macStatus)
    let awake = KeepAwake()
    let keyboard = KeyboardLock()
    @Published var hiddenTabs: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "hiddenTabs") ?? []) {
        didSet {
            UserDefaults.standard.set(Array(hiddenTabs), forKey: "hiddenTabs")
            if hiddenTabs.contains(selectedTab.rawValue) { selectedTab = NotchTab.allCases.first { !hiddenTabs.contains($0.rawValue) } ?? .options }
            layout()
        }
    }
    func tabVisible(_ tab: NotchTab) -> Bool { !hiddenTabs.contains(tab.rawValue) }
    func setTabVisible(_ tab: NotchTab, _ visible: Bool) {
        if visible { hiddenTabs.remove(tab.rawValue) } else { hiddenTabs.insert(tab.rawValue) }
    }
    @Published var showKeyboardButton = UserDefaults.standard.object(forKey: "showKeyboardButton") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showKeyboardButton, forKey: "showKeyboardButton"); layout() }
    }
    var hasFloatingButtons: Bool { showAwakeButton || showKeyboardButton }
    @Published var showAwakeButton = UserDefaults.standard.object(forKey: "showAwakeButton") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showAwakeButton, forKey: "showAwakeButton"); layout() }
    }
    let music = MusicModel()
    let brew = BrewModel()
    let clipboard = ClipboardModel()
    let audio = AudioModel()
    let mixer = MixerModel()
    @Published var compactMode: String = UserDefaults.standard.string(forKey: "compactMode") ?? "agents" {
        didSet { UserDefaults.standard.set(compactMode, forKey: "compactMode"); layout() }
    }
    var defaultTab: NotchTab { compactMode == "mac" ? .mac : (compactMode == "music" ? .music : .agents) }
    @Published var selectedTab: NotchTab = NotchTab(rawValue: UserDefaults.standard.string(forKey: "lastNotchTab") ?? "agents") ?? .agents {
        didSet { UserDefaults.standard.set(selectedTab.rawValue, forKey: "lastNotchTab"); layout() }
    }
    var tabBeforeDrag: NotchTab?
    var showingFiles: Bool {
        get { selectedTab == .files }
        set { selectedTab = newValue ? .files : defaultTab }
    }
    var panel: NSPanel?
    var optionsWindow: NSWindow?
    private var screenPanels: [String: NSPanel] = [:]
    @Published var expandedScreens: Set<String> = []
    @Published var notchWidth: CGFloat = 180
    @Published var top: CGFloat = 32
    @Published var size: Int = UserDefaults.standard.object(forKey: "notchSize") as? Int ?? 1 {
        didSet { UserDefaults.standard.set(size, forKey: "notchSize"); layout() }
    }
    @Published var showClaude = UserDefaults.standard.object(forKey: "showClaude") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showClaude, forKey: "showClaude"); layout() }
    }
    @Published var showCodex = UserDefaults.standard.object(forKey: "showCodex") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showCodex, forKey: "showCodex"); layout() }
    }
    @Published var showRAM = UserDefaults.standard.object(forKey: "showRAM") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showRAM, forKey: "showRAM"); layout() }
    }
    @Published var showDisk = UserDefaults.standard.object(forKey: "showDisk") as? Bool ?? false {
        didSet { UserDefaults.standard.set(showDisk, forKey: "showDisk"); layout() }
    }
    @Published var availableScreens: [NSScreen] = NSScreen.screens
    @Published var preferredScreen = UserDefaults.standard.string(forKey: "preferredScreen") ?? "auto" {
        didSet { UserDefaults.standard.set(preferredScreen, forKey: "preferredScreen"); layout() }
    }
    func screenID(_ screen: NSScreen) -> String {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue ?? "unknown"
    }
    var screenObserver: NSObjectProtocol?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        claudeSession.restore()
        if UserDefaults.standard.string(forKey: "lastNotchTab") == nil { selectedTab = defaultTab }
        if !tabVisible(selectedTab) { selectedTab = NotchTab.allCases.first { tabVisible($0) } ?? .options }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.availableScreens = NSScreen.screens; self?.layout() }
        layout()
    }
    func showOptions() {
        selectedTab = .options
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
        let id = screen.map(screenID).flatMap { screenPanels[$0] != nil ? $0 : nil } ?? screenPanels.keys.sorted().first
        if let id { expandedScreens.insert(id) }
        layout()
        if let id { screenPanels[id]?.makeKeyAndOrderFront(nil) }
    }
    func layout() {
        let screens: [NSScreen]
        if preferredScreen == "all" { screens = NSScreen.screens }
        else if let screen = NSScreen.screens.first(where: { screenID($0) == preferredScreen }) ?? NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main { screens = [screen] }
        else { screens = [] }
        let ids = Set(screens.map(screenID))
        for id in Array(screenPanels.keys) where !ids.contains(id) {
            screenPanels.removeValue(forKey: id)?.close()
            expandedScreens.remove(id)
        }
        for screen in screens { layout(on: screen) }
        panel = screens.first.flatMap { screenPanels[screenID($0)] }
    }
    private func layout(on screen: NSScreen) {
        let id = screenID(screen)
        let expanded = expandedScreens.contains(id)
        let panel: NSPanel
        let isNew = screenPanels[id] == nil
        if let existing = screenPanels[id] { panel = existing }
        else {
            panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.isReleasedWhenClosed = false
            screenPanels[id] = panel
        }
        let gap: CGFloat
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            gap = max(180, right.minX - left.maxX)
        } else { gap = 180 }
        let safeTop = max(32, screen.safeAreaInsets.top)
        if notchWidth != gap { notchWidth = gap }
        if top != safeTop { top = safeTop }
        let preset = min(2, max(0, size))
        let side: CGFloat = [84, 156, 220][preset] + (showClaude && showCodex ? (preset == 0 ? 24 : 60) : 0)
        let detailWidth: CGFloat = [420, 660, 780][preset]
        let width = min(screen.frame.width - 20, expanded ? max(detailWidth, gap + side) : gap)
        let detailsHeight: CGFloat
        switch selectedTab {
        case .files: detailsHeight = [170, 210, 230][preset]
        case .agents: detailsHeight = (showClaude || showCodex) ? [270, 390, 410][preset] : [170, 210, 230][preset]
        case .mac: detailsHeight = [540, 630, 680][preset]
        case .music: detailsHeight = [270, 320, 390][preset]
        case .brew, .clipboard, .audio, .options: detailsHeight = [400, 460, 500][preset]
        }
        let height = expanded ? min(screen.visibleFrame.height, safeTop + 18 + detailsHeight + (hasFloatingButtons ? 54 : 0)) : safeTop + 18
        let upperEdge = screen.frame.maxY
        panel.setFrame(NSRect(x: screen.frame.midX - width / 2, y: upperEdge - height, width: width, height: height), display: true)
        if let host = panel.contentView as? ShelfHostingView {
            if host.rootView.screenTop != safeTop { host.rootView = NotchView(monitor: monitor, controller: self, screenTop: safeTop, screenIdentifier: id) }
        } else {
            panel.contentView = ShelfHostingView(controller: self, top: safeTop, screenID: id)
        }
        if isNew { panel.orderFrontRegardless() }
    }
}

private var appVersionLabel: String {
    let info = Bundle.main.infoDictionary ?? [:]
    return "NekoNotch \(info["CFBundleShortVersionString"] as? String ?? "—")"
}

struct OptionsView: View {
    @ObservedObject var controller: NotchController
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Opciones").font(.title2.bold()).padding(.bottom, 4)
            Text(appVersionLabel).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            group("General", icon: "slider.horizontal.3") {
                Picker("Pantalla", selection: $controller.preferredScreen) {
                    Text("Automática").tag("auto")
                    Text("Todas las pantallas").tag("all")
                    ForEach(controller.availableScreens, id: \.self) { screen in
                        Text(screen.localizedName).tag(controller.screenID(screen))
                    }
                    if controller.preferredScreen != "auto" && controller.preferredScreen != "all" && !controller.availableScreens.contains(where: { controller.screenID($0) == controller.preferredScreen }) {
                        Text("Pantalla desconectada").tag(controller.preferredScreen)
                    }
                }
                Text("Tamaño").font(.caption).foregroundStyle(.gray)
                Picker("Tamaño", selection: $controller.size) {
                    Text("Compacto").tag(0)
                    Text("Normal").tag(1)
                    Text("Grande").tag(2)
                }.pickerStyle(.segmented).labelsHidden()
                Text("Cuando está pequeño").font(.caption).foregroundStyle(.gray)
                Picker("Contenido del notch", selection: $controller.compactMode) {
                    Text("IA").tag("agents")
                    Text("Monitor").tag("mac")
                    Text("Reproductor").tag("music")
                }.pickerStyle(.segmented).labelsHidden()
            }
            group("IA", icon: "sparkles") {
                tabVisibility(.agents)
                ClaudeConnectionView(session: controller.claudeSession)
                Toggle("Mostrar límites de Claude", isOn: $controller.showClaude)
                Toggle("Mostrar límites de Codex", isOn: $controller.showCodex)
            }
            group("Mac", icon: "desktopcomputer") {
                tabVisibility(.mac)
                Toggle("Mostrar botón de pantalla encendida", isOn: $controller.showAwakeButton)
                Toggle("Mostrar botón de teclado", isOn: $controller.showKeyboardButton)
                KeyboardOptions(model: controller.keyboard)
                AwakeOptions(awake: controller.awake)
            }
            group("Archivos", icon: "tray") {
                tabVisibility(.files)
            }
            group("Reproductor", icon: "music.note") {
                tabVisibility(.music)
            }
            group("Audio", icon: "speaker.wave.2") {
                tabVisibility(.audio)
            }
            group("Brew", icon: "mug") {
                tabVisibility(.brew)
            }
            group("Portapapeles", icon: "doc.on.clipboard") {
                tabVisibility(.clipboard)
                ClipboardOptions(model: controller.clipboard)
            }
            group("Opciones", icon: "gearshape") {
                tabVisibility(.options)
                Text("Siempre podés abrir Opciones desde el menú del gatito.").font(.caption).foregroundStyle(.secondary)
            }
        }.font(.system(size: 12)).toggleStyle(.switch).padding(4).frame(maxWidth: .infinity, alignment: .leading)
    }
    func tabVisibility(_ tab: NotchTab) -> some View {
        Toggle("Mostrar pestaña", isOn: Binding(get: { controller.tabVisible(tab) }, set: { controller.setTabVisible(tab, $0) }))
            .font(.system(size: 13, weight: .semibold))
            .accessibilityLabel("Mostrar pestaña \(tab.title)")
    }
    func group<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon).font(.system(size: 14, weight: .semibold))
            Divider()
            content()
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Color(white: 0.065), in: RoundedRectangle(cornerRadius: 20))
    }
}

struct SmallNotchInfo: View {
    let expanded: Bool
    @ObservedObject var controller: NotchController
    @ObservedObject var monitor: Monitor
    @ObservedObject var mac: MacStatus
    @ObservedObject var music: MusicModel
    func percent(_ value: Double?) -> String { guard let value, value.isFinite, (0...100).contains(value) else { return "—" }; return "\(Int(value.rounded()))%" }
    var body: some View {
        HStack(spacing: 10) {
            switch controller.defaultTab {
            case .mac:
                Text("CPU \(percent(mac.cpu))").foregroundStyle(.blue)
                Text("RAM \(percent(mac.memoryPercent))").foregroundStyle(.purple)
            case .music:
                Image(systemName: music.hasMedia ? (music.playing ? "waveform" : "pause.fill") : "music.note").foregroundStyle(.purple)
                Text(music.hasMedia ? music.title : "Sin reproducción").lineLimit(1).truncationMode(.tail).frame(maxWidth: expanded ? 240 : 125, alignment: .leading).help(music.title)
            default:
                if controller.showClaude { Text("C \(percent(monitor.sample?.u.fh))\(monitor.claudeIsStale && monitor.sample != nil ? "*" : "")").foregroundStyle(Color(red: 0.82, green: 0.44, blue: 0.32)) }
                if controller.showCodex { Text("X \(percent(monitor.codex?.windows.first?.used_percent))").foregroundStyle(Color(red: 0.48, green: 0.57, blue: 0.94)) }
                if !controller.showClaude && !controller.showCodex { Image(systemName: "sparkles").foregroundStyle(.gray) }
            }
        }.font(.system(size: 10, weight: .semibold, design: .rounded)).monospacedDigit().frame(maxWidth: .infinity).frame(height: 18)
    }
}

struct NotchOutline: Shape {
    var radius: CGFloat
    func path(in rect: CGRect) -> Path {
        let r = min(radius, min(rect.width, rect.height) / 2)
        return Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
            path.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
            path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r), control: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}

struct AwakeFloatingButton: View {
    @ObservedObject var awake: KeepAwake
    var body: some View {
        Button { awake.setEnabled(!awake.enabled) } label: {
            Image(systemName: awake.enabled ? "cup.and.saucer.fill" : "cup.and.saucer")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(awake.enabled ? .orange : .white)
                .frame(width: 44, height: 44)
                .background(.black, in: Circle())
                .overlay(Circle().stroke(awake.enabled ? Color.orange : Color.white.opacity(0.55), lineWidth: 1))
                .contentShape(Circle())
        }.buttonStyle(.plain)
        .help(awake.error ?? (awake.enabled ? "Pantalla encendida · tocar para desactivar" : "Mantener pantalla encendida"))
        .accessibilityLabel(awake.enabled ? "Desactivar pantalla siempre encendida" : "Activar pantalla siempre encendida")
    }
}
struct AwakeOptions: View {
    @ObservedObject var awake: KeepAwake
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Toggle("Mantener pantalla encendida", isOn: Binding(get: { awake.enabled }, set: awake.setEnabled)).toggleStyle(.switch)
            if let error = awake.error { Text(error).font(.caption).foregroundStyle(.orange) }
        }
    }
}

struct NotchView: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject var controller: NotchController
    @ObservedObject var shelf: FileShelf
    let screenTop: CGFloat
    let screenIdentifier: String
    var expanded: Bool { controller.expandedScreens.contains(screenIdentifier) }
    init(monitor: Monitor, controller: NotchController, screenTop: CGFloat, screenIdentifier: String) {
        self.screenTop = screenTop
        self.screenIdentifier = screenIdentifier
        self.monitor = monitor
        self.controller = controller
        self.shelf = controller.shelf
    }
    var compact: Bool { controller.size == 0 }
    var cardPadding: CGFloat { compact ? 10 : 16 }
    var cardRadius: CGFloat { compact ? 16 : 24 }
    func percent(_ value: Double?) -> String {
        guard let value, value.isFinite, (0...100).contains(value) else { return "—" }
        return "\(Int(value.rounded()))%"
    }
    var body: some View {
        VStack(spacing: expanded && controller.hasFloatingButtons ? 10 : 0) {
            mainContent
            if expanded && controller.hasFloatingButtons {
                HStack(spacing: 12) {
                    if controller.showAwakeButton { AwakeFloatingButton(awake: controller.awake) }
                    if controller.showKeyboardButton { KeyboardFloatingButton(model: controller.keyboard) }
                }.frame(height: 44)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
        .onHover { inside in
            guard !controller.draggingFile, expanded != inside else { return }
            if !inside && controller.keyboard.locked { return }
            if !inside && controller.selectedTab == .brew && (controller.brew.pending != nil || controller.brew.busy) { return }
            if inside { controller.expandedScreens.insert(screenIdentifier) } else { controller.expandedScreens.remove(screenIdentifier) }
            controller.layout()
        }
    }
    var mainContent: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: screenTop)
            SmallNotchInfo(expanded: expanded, controller: controller, monitor: monitor, mac: controller.macStatus, music: controller.music)
            if expanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: compact ? 8 : 14) {
                        HStack(spacing: compact ? 4 : 8) {
                            ForEach(NotchTab.allCases.filter { controller.tabVisible($0) }, id: \.self) { item in
                                tab(item.title, icon: item.icon, selection: item)
                            }
                        }.frame(maxWidth: .infinity).padding(.bottom, 4)
                        if controller.showingFiles {
                            FileShelfView(shelf: shelf, compact: compact, targeted: controller.draggingFile)
                        } else if controller.selectedTab == .mac {
                            MacStatusView(model: controller.macStatus, awake: controller.awake)
                        } else if controller.selectedTab == .music {
                            MusicView(model: controller.music, audio: controller.audio, size: controller.size)
                        } else if controller.selectedTab == .brew {
                            BrewView(model: controller.brew)
                        } else if controller.selectedTab == .audio {
                            AudioView(model: controller.audio, mixer: controller.mixer)
                        } else if controller.selectedTab == .clipboard {
                            ClipboardView(model: controller.clipboard)
                        } else if controller.selectedTab == .options {
                            OptionsView(controller: controller)
                        } else {
                        if controller.showClaude || controller.showCodex {
                            HStack(alignment: .top, spacing: compact ? 8 : 12) {
                                if controller.showClaude { claudeCard }
                                if controller.showCodex { codexCard }
                            }
                        }
                        recordsCard
                        AIConsumptionView(store: monitor.history, monitor: monitor, showClaude: controller.showClaude, showCodex: controller.showCodex)
                        }
                    }.padding(.horizontal, compact ? 12 : 18).padding(.top, compact ? 8 : 15).padding(.bottom, compact ? 8 : 16)
                }.scrollIndicators(.hidden)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(.white).background(.black, in: NotchOutline(radius: expanded ? 18 : 10))
        .preferredColorScheme(.dark)
    }
    func tab(_ title: String, icon: String, selection: NotchTab) -> some View {
        Button { controller.selectedTab = selection } label: {
            Image(systemName: icon)
                .font(.system(size: compact ? 15 : 19, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.horizontal, compact ? 3 : 6).padding(.vertical, compact ? 6 : 8)
                .foregroundStyle(controller.selectedTab == selection ? .white : .gray)
                .background(controller.selectedTab == selection ? Color(white: 0.14) : .clear, in: Capsule())
                .contentShape(Rectangle())
        }.buttonStyle(.plain).frame(maxWidth: .infinity).help(title).accessibilityLabel(title)
    }
    var claudeColor: Color { Color(red: 0.82, green: 0.44, blue: 0.32) }
    var codexColor: Color { Color(red: 0.48, green: 0.57, blue: 0.94) }
    var cardColor: Color { Color(white: 0.065) }
    func cardHeader(_ name: String, icon: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: compact ? 15 : 19)).foregroundStyle(color)
            Text(name).font(.system(size: compact ? 13 : 16, weight: .semibold))
            Spacer(minLength: 0)
            Text("Uso").font(.system(size: 10, weight: .medium)).foregroundStyle(color).padding(.horizontal, 8).padding(.vertical, 4).background(color.opacity(0.16), in: Capsule())
        }.padding(.bottom, 4)
    }
    var claudeCard: some View {
        VStack(alignment: .leading, spacing: compact ? 7 : 10) {
            cardHeader("Claude", icon: "sparkle", color: claudeColor)
            usageBar("Sesión", value: monitor.sample?.u.fh, reset: monitor.sample?.resets?["fh"], color: claudeColor)
            usageBar("Semana", value: monitor.sample?.u.sd, reset: monitor.sample?.resets?["sd"], color: claudeColor)
            if monitor.claudeIsStale {
                Text("Dato desactualizado").font(.system(size: 10, weight: .medium)).foregroundStyle(.orange)
            } else if !compact && monitor.sample?.resets == nil { Text("Restablecimiento: ver en Claude").font(.system(size: 10)).foregroundStyle(.gray) }
        }.padding(cardPadding).frame(maxWidth: .infinity, minHeight: compact ? 115 : 170, alignment: .topLeading).background(cardColor, in: RoundedRectangle(cornerRadius: cardRadius))
    }
    var codexCard: some View {
        VStack(alignment: .leading, spacing: compact ? 7 : 10) {
            cardHeader("Codex", icon: "chevron.left.forwardslash.chevron.right", color: codexColor)
            if let sample = monitor.codex {
                ForEach(Array(sample.windows.enumerated()), id: \.offset) { _, window in
                    usageBar(window.window_minutes == 300 ? "Sesión" : (window.window_minutes == 10080 ? "Semana" : "\(window.window_minutes) min"), value: window.used_percent, reset: window.resets_at, color: codexColor)
                }
                if !compact { Text("Horarios según tu cuenta").font(.system(size: 10)).foregroundStyle(.gray) }
            } else {
                usageBar("Sesión", value: nil, reset: nil, color: codexColor)
                Text("Usá Codex para registrar tus límites.").font(.caption).foregroundStyle(.gray)
            }
        }.padding(cardPadding).frame(maxWidth: .infinity, minHeight: compact ? 115 : 170, alignment: .topLeading).background(cardColor, in: RoundedRectangle(cornerRadius: cardRadius))
    }
    func usageBar(_ title: String, value: Double?, reset: Double?, color: Color) -> some View {
        let valid = value.map { $0.isFinite && (0...100).contains($0) } ?? false
        return VStack(spacing: 5) {
            HStack(spacing: 5) {
                Text(title).font(.system(size: compact ? 11 : 13))
                if let reset {
                    Image(systemName: "arrow.clockwise").font(.system(size: 9)).foregroundStyle(.gray)
                    Text(countdown(reset)).font(.system(size: 10)).foregroundStyle(.gray).lineLimit(1)
                }
                Spacer(minLength: 2)
                Text(percent(value)).font(.system(size: compact ? 14 : 17, weight: .semibold)).monospacedDigit()
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(white: 0.18))
                    if valid, let value { Capsule().fill(value >= 90 ? Color.orange : color).frame(width: geometry.size.width * value / 100) }
                }
            }.frame(height: compact ? 8 : 12)
        }.help(reset.map { "Se restablece: \(Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .shortened))" } ?? "No hay horario de restablecimiento disponible")
    }
    func countdown(_ epoch: Double) -> String {
        let minutes = Int((epoch - monitor.updated.timeIntervalSince1970) / 60)
        if minutes <= 0 { return "Pendiente" }
        if minutes >= 1440 { return "\(minutes / 1440)d \((minutes % 1440) / 60)h" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }
    var recordsCard: some View {
        VStack(alignment: .leading, spacing: compact ? 7 : 12) {
            Label("Último registro", systemImage: "waveform.path.ecg").font(.system(size: compact ? 12 : 15, weight: .semibold)).foregroundStyle(Color(white: 0.85))
            if controller.showClaude { recordRow("Claude", icon: "sparkle", color: claudeColor, date: monitor.sample.map { Date(timeIntervalSince1970: $0.t / 1000) }) }
            if controller.showCodex { recordRow("Codex", icon: "chevron.left.forwardslash.chevron.right", color: codexColor, date: monitor.codex?.date) }
            if !controller.showClaude && !controller.showCodex { Text("Activá un agente en Opciones.").font(.caption).foregroundStyle(.gray) }
        }.padding(cardPadding).frame(maxWidth: .infinity, minHeight: compact ? 82 : 112, alignment: .topLeading).background(cardColor, in: RoundedRectangle(cornerRadius: cardRadius))
    }
    func recordRow(_ title: String, icon: String, color: Color, date: Date?) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(color)
            Text(title)
            Spacer(minLength: 2)
            Text(age(date)).foregroundStyle(.gray).font(.system(size: 11))
        }.font(.system(size: compact ? 11 : 13)).help(date.map { "\($0.formatted(date: .abbreviated, time: .shortened))\(monitor.updated.timeIntervalSince($0) > 900 ? " · Datos atrasados" : "")" } ?? "Sin datos")
    }
    func age(_ date: Date?) -> String {
        guard let date else { return "Sin datos" }
        let minutes = max(0, Int(monitor.updated.timeIntervalSince(date) / 60))
        if minutes == 0 { return "Ahora" }
        if minutes < 60 { return "Hace \(minutes) min" }
        if minutes < 1440 { return "Hace \(minutes / 60) h" }
        return "Hace \(minutes / 1440) d"
    }

}

struct FileShelfView: View {
    @ObservedObject var shelf: FileShelf
    let compact: Bool
    let targeted: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Bandeja de archivos", systemImage: "tray").font(.system(size: compact ? 12 : 15, weight: .semibold))
                Spacer()
                Text("\(shelf.files.count)").font(.caption).foregroundStyle(.gray)
            }
            if shelf.files.isEmpty {
                Text("Sin archivos").font(.system(size: compact ? 11 : 13)).foregroundStyle(.gray).frame(maxWidth: .infinity, minHeight: compact ? 24 : 38)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(shelf.files, id: \.self) { url in
                            ShelfFileView(shelf: shelf, url: url, compact: compact)
                        }
                    }
                }.scrollIndicators(.hidden)
            }
        }.padding(compact ? 10 : 14).background(Color(white: targeted ? 0.12 : 0.065), in: RoundedRectangle(cornerRadius: compact ? 16 : 24))
        .overlay(RoundedRectangle(cornerRadius: compact ? 16 : 24).stroke(targeted ? Color.blue : Color.white.opacity(0.1), style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
    }
}

final class ShelfThumbnail: ObservableObject {
    @Published var image: NSImage?
}

final class ShelfPreviewWindow: NSWindowController {
    static let shared = ShelfPreviewWindow()
    private let previewView = QLPreviewView(frame: NSRect(x: 0, y: 0, width: 680, height: 520), style: .normal)!
    private init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 520), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = previewView
        panel.center()
        super.init(window: panel)
    }
    required init?(coder: NSCoder) { fatalError() }
    func preview(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        previewView.previewItem = url as NSURL
        window?.title = url.lastPathComponent
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct ShelfFileView: View {
    @ObservedObject var shelf: FileShelf
    let url: URL
    let compact: Bool
    @StateObject(wrappedValue: ShelfThumbnail()) private var thumbnail
    var exists: Bool { FileManager.default.fileExists(atPath: url.path) }
    var body: some View {
        HStack(spacing: 7) {
            Button { ShelfPreviewWindow.shared.preview(url) } label: {
                Image(nsImage: thumbnail.image ?? NSWorkspace.shared.icon(forFile: url.path))
                    .resizable().scaledToFit()
                    .frame(width: compact ? 42 : 60, height: compact ? 42 : 60)
                    .background(.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }.buttonStyle(.plain).disabled(!exists).help("Vista previa")
                .accessibilityLabel("Vista previa de \(url.lastPathComponent)")
            if !exists {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help("Original no disponible")
            }
            Menu {
                Button("Vista previa") { ShelfPreviewWindow.shared.preview(url) }.disabled(!exists)
                Button("Copiar archivo") { shelf.copy(url) }.disabled(!exists)
                Button("Mostrar en Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.disabled(!exists)
                Button("Quitar de la bandeja") { shelf.remove(url) }
            } label: { Image(systemName: "ellipsis").font(.caption) }.menuStyle(.borderlessButton).fixedSize()
            Button { shelf.remove(url) } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Quitar de la bandeja")
                .accessibilityLabel("Quitar \(url.lastPathComponent) de la bandeja")
        }.padding(8).background(Color(white: 0.13), in: RoundedRectangle(cornerRadius: 10))
        .onDrag {
            guard exists else { return NSItemProvider() }
            return NSItemProvider(contentsOf: url) ?? NSItemProvider(object: url as NSURL)
        }
        .contextMenu {
            Button("Vista previa") { ShelfPreviewWindow.shared.preview(url) }.disabled(!exists)
            Button("Copiar archivo") { shelf.copy(url) }.disabled(!exists)
            Button("Mostrar en Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.disabled(!exists)
            Button("Quitar de la bandeja") { shelf.remove(url) }
        }
        .task(id: url) {
            guard exists else { return }
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 120, height: 120), scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .all)
            if let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request), !Task.isCancelled {
                thumbnail.image = representation.nsImage
            }
        }
        .help(url.path)
    }
}

final class CatRunner: ObservableObject {
    @Published private(set) var frame = 0
    let images: [NSImage] = (0..<12).map { CatRunner.draw(frame: $0) }
    private var phase = 0.0
    private var lastUpdate = Date()
    private var timer: Timer?
    init(mac: MacStatus) {
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self, weak mac] _ in
            guard let self else { return }
            let now = Date(); let elapsed = min(0.2, now.timeIntervalSince(self.lastUpdate)); self.lastUpdate = now
            let cpu = min(100, max(0, mac?.cpu ?? 0))
            // 0.45 strides/second at idle, 3.2 at full CPU.
            self.phase = (self.phase + elapsed * (0.45 + 2.75 * cpu / 100)).truncatingRemainder(dividingBy: 1)
            let next = Int(self.phase * 12) % 12
            if self.frame != next { self.frame = next }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }
    static func draw(frame: Int) -> NSImage {
        let image = NSImage(size: NSSize(width: 32, height: 22), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState(); defer { context.restoreGState() }
            context.scaleBy(x: 0.66, y: 0.66)
            NSColor.black.setFill(); NSColor.black.setStroke()
            let angle = Double(frame) / 12 * 2 * Double.pi
            let bob = CGFloat(0.7 * sin(angle * 2))
            // Long, upward-curving tail and arched back, like the reference.
            let tail = NSBezierPath(); tail.move(to: NSPoint(x: 17, y: 16 + bob)); tail.curve(to: NSPoint(x: 3, y: 28 + CGFloat(sin(angle))), controlPoint1: NSPoint(x: 13, y: 26 + bob), controlPoint2: NSPoint(x: 8, y: 29)); tail.lineWidth = 2.4; tail.lineCapStyle = .round; tail.stroke()
            for (index, x) in [CGFloat(18), 21, 31, 34].enumerated() {
                let offset = angle + (index % 2 == 0 ? 0 : Double.pi) + (index >= 2 ? Double.pi / 2 : 0)
                let footX = x + CGFloat(sin(offset) * 5.2)
                let footY = CGFloat(4 + max(0, cos(offset)) * 5)
                let leg = NSBezierPath(); leg.move(to: NSPoint(x: x, y: 14 + bob)); leg.line(to: NSPoint(x: x + CGFloat(sin(offset) * 2), y: 8 + bob)); leg.line(to: NSPoint(x: footX, y: footY)); leg.line(to: NSPoint(x: footX + 2, y: footY - 0.3)); leg.lineWidth = index % 2 == 0 ? 3.4 : 2.6; leg.lineCapStyle = .round; leg.lineJoinStyle = .round; leg.stroke()
            }
            let body = NSBezierPath(); body.move(to: NSPoint(x: 14, y: 12 + bob)); body.curve(to: NSPoint(x: 23, y: 22 + bob), controlPoint1: NSPoint(x: 11, y: 19 + bob), controlPoint2: NSPoint(x: 18, y: 24 + bob)); body.curve(to: NSPoint(x: 35, y: 17 + bob), controlPoint1: NSPoint(x: 28, y: 22 + bob), controlPoint2: NSPoint(x: 30, y: 16 + bob)); body.line(to: NSPoint(x: 35, y: 11 + bob)); body.curve(to: NSPoint(x: 14, y: 12 + bob), controlPoint1: NSPoint(x: 27, y: 9 + bob), controlPoint2: NSPoint(x: 22, y: 14 + bob)); body.close(); body.fill()
            NSBezierPath(ovalIn: NSRect(x: 31, y: 13 + bob, width: 12, height: 11)).fill()
            let ears = NSBezierPath(); ears.move(to: NSPoint(x: 31.5, y: 20 + bob)); ears.line(to: NSPoint(x: 32, y: 27 + bob)); ears.line(to: NSPoint(x: 37, y: 23 + bob)); ears.move(to: NSPoint(x: 37, y: 23 + bob)); ears.line(to: NSPoint(x: 42, y: 28 + bob)); ears.line(to: NSPoint(x: 42.5, y: 20 + bob)); ears.fill()
            NSBezierPath(ovalIn: NSRect(x: 40, y: 14.5 + bob, width: 5, height: 4)).fill()
            let whiskers = NSBezierPath(); whiskers.move(to: NSPoint(x: 41, y: 17 + bob)); whiskers.line(to: NSPoint(x: 47, y: 19 + bob)); whiskers.move(to: NSPoint(x: 41, y: 15 + bob)); whiskers.line(to: NSPoint(x: 46, y: 14 + bob)); whiskers.lineWidth = 1; whiskers.stroke()
            // Transparent eyes stay visible in both light and dark menu bars.
            context.setBlendMode(.destinationOut)
            NSBezierPath(ovalIn: NSRect(x: 34.8, y: 19 + bob, width: 2.2, height: 2.8)).fill()
            NSBezierPath(ovalIn: NSRect(x: 39.2, y: 19.5 + bob, width: 2, height: 2.5)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}
struct CatStatusIcon: View {
    @ObservedObject var runner: CatRunner
    @ObservedObject var mac: MacStatus
    var body: some View {
        Image(nsImage: runner.images[runner.frame]).renderingMode(.template)
            .accessibilityLabel("Mi Mac · gatito corriendo")
            .help("Mi Mac · CPU \(Int((mac.cpu ?? 0).rounded()))%")
    }
}

@main
struct MiMacApp: App {
    @NSApplicationDelegateAdaptor(NotchController.self) var delegate
    var body: some Scene {
        Settings {
            ScrollView(.vertical) {
                OptionsView(controller: delegate)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(minWidth: 520, idealWidth: 640, minHeight: 360, idealHeight: 640)
        }
            .defaultSize(width: 640, height: 640)
            .commands { CommandGroup(replacing: .appSettings) { Button("Opciones de Mi Mac…", action: delegate.showOptions).keyboardShortcut(",") } }
        MenuBarExtra {
            Text(appVersionLabel)
            Divider()
            Button("Opciones…", action: delegate.showOptions)
            Button("Actualizar", action: delegate.monitor.refresh)
            KeyboardMenuAction(model: delegate.keyboard)
            Divider()
            Button("Salir de Mi Mac") { NSApp.terminate(nil) }
        } label: {
            CatStatusIcon(runner: delegate.catRunner, mac: delegate.macStatus)
        }
    }
}

struct ClaudeConnectionView: View {
    @ObservedObject var session: ClaudeSession
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Sesión de Claude")
                    Text(session.status).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Conectar Claude", action: session.connect)
            }
            if !session.organizations.isEmpty {
                Picker("Organización", selection: $session.organization) {
                    Text("Elegí una organización").tag("")
                    ForEach(session.organizations) { item in Text(item.name).tag(item.id) }
                }
                Button("Actualizar límites", action: session.refresh)
            }
        }
    }
}
