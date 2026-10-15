import AppKit
import WebKit

// Authentication stays in WebKit's local cookie store. No cookies or tokens are exported.
struct ClaudeOrganization: Identifiable { let id: String; let name: String }

final class ClaudeSession: NSObject, ObservableObject, WKNavigationDelegate {
    @Published var status = "Sin conectar"
    @Published var organizations: [ClaudeOrganization] = []
    @Published var organization = UserDefaults.standard.string(forKey: "claudeOrganization") ?? "" {
        didSet {
            UserDefaults.standard.set(organization, forKey: "claudeOrganization")
            refresh()
        }
    }
    private var window: NSWindow?
    private var web: WKWebView?
    private var timer: Timer?
    private var polling = false
    func connect() {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 740), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Conectar Claude · NekoNotch"
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.center()
        self.window = window; web = view
        view.load(URLRequest(url: URL(string: "https://claude.ai/settings/usage")!))
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        UserDefaults.standard.set(true, forKey: "claudeWebStarted")
        status = "Iniciá sesión en la ventana de Claude"
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { refresh() }
    func refresh() {
        guard !polling, let web, web.url?.host == "claude.ai" else { return }
        polling = true
        web.callAsyncJavaScript("""
        const orgResponse = await fetch('/api/organizations', {credentials:'same-origin'});
        if (!orgResponse.ok) return {error:'login'};
        const orgs = await orgResponse.json();
        if (!Array.isArray(orgs) || !orgs.length) return {error:'organization'};
        const selected = orgs.length === 1 ? orgs[0] : orgs.find(o => o.uuid === organization);
        const organizations = orgs.map(o => ({id:o.uuid, name:o.name || 'Organización'}));
        if (!selected) return {error:'multiple', organizations};
        const response = await fetch('/api/organizations/' + encodeURIComponent(selected.uuid) + '/usage', {credentials:'same-origin'});
        if (!response.ok) return {error:'usage'};
        return {usage:await response.json(), organizations};
        """, arguments: ["organization": UserDefaults.standard.string(forKey: "claudeOrganization") ?? ""], in: nil, in: .page, completionHandler: { [weak self] result in
            guard let self else { return }; polling = false
            guard case .success(let raw) = result, let object = raw as? [String: Any] else { status = "No se pudo leer el uso de Claude"; return }
            if let list = object["organizations"] as? [[String: Any]] {
                organizations = list.compactMap { item in
                    guard let id = item["id"] as? String, let name = item["name"] as? String else { return nil }
                    return ClaudeOrganization(id: id, name: name)
                }
            }
            if let error = object["error"] as? String {
                status = error == "multiple" ? "Más de una organización: conexión pendiente" : "Iniciá sesión o revisá la página de uso"
                return
            }
            guard let data = object["usage"] as? [String: Any] else { status = "No se pudo leer el uso"; return }
            var usage: [String: Double] = [:]; var resets: [String: Double] = [:]
            for (key, short) in [("five_hour", "fh"), ("seven_day", "sd")] {
                guard let bucket = data[key] as? [String: Any], let value = bucket["utilization"] as? Double, value.isFinite, (0...100).contains(value) else { continue }
                usage[short] = value
                if let text = bucket["resets_at"] as? String {
                    let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    if let date = formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text) { resets[short] = date.timeIntervalSince1970 }
                }
            }
            guard !usage.isEmpty else { status = "Claude no devolvió límites disponibles"; return }
            let sample: [String: Any] = ["t": Date().timeIntervalSince1970 * 1000, "org": "claude-web", "u": usage, "resets": resets]
            do {
                let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MiMac/claude-web-usage.json")
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONSerialization.data(withJSONObject: sample).write(to: file, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                UserDefaults.standard.set(true, forKey: "claudeWebConnected")
                status = "Conectado · actualización cada minuto"
            } catch { status = "No se pudo guardar la lectura" }
        })
    }
    func restore() { if UserDefaults.standard.bool(forKey: "claudeWebStarted") || UserDefaults.standard.bool(forKey: "claudeWebConnected") { connect(); window?.orderOut(nil) } }
}
