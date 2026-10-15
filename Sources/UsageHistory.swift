import SwiftUI

struct QuotaPoint: Codable {
    let source: String
    let window: String
    let account: String?
    let date: Date
    let used: Double
    let reset: Double?
    var series: String { source + " · " + window }
}
final class UsageHistoryStore: ObservableObject {
    @Published var points: [QuotaPoint] = []
    @Published var error: String?
    let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MiMac/usage-history.json")
    init() {
        if let data = try? Data(contentsOf: file) { points = (try? JSONDecoder().decode([QuotaPoint].self, from: data)) ?? [] }
    }
    func add(_ new: [QuotaPoint]) {
        var changed = false
        for point in new where point.used.isFinite && (0...100).contains(point.used) {
            guard !points.contains(where: { $0.source == point.source && $0.window == point.window && $0.account == point.account && $0.date == point.date && $0.used == point.used }) else { continue }
            points.removeAll { $0.source == point.source && $0.window == point.window && $0.account == point.account && $0.date == point.date }
            points.append(point); changed = true
        }
        guard changed else { return }
        points = Array(points.filter { $0.date > Date().addingTimeInterval(-30 * 86400) }.sorted { $0.date < $1.date }.suffix(15000))
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(points).write(to: file, options: .atomic)
        } catch { self.error = "No se pudo guardar el historial de uso." }
    }
    func claude(_ sample: Sample) {
        let date = Date(timeIntervalSince1970: sample.t / 1000)
        let values: [(String, Double?)] = [("Sesión", sample.u.fh), ("Semana", sample.u.sd)] + sample.u.extra.sorted(by: { $0.key < $1.key }).map { ($0.key, Optional($0.value)) }
        add(values.compactMap { name, value in value.map { QuotaPoint(source: "Claude", window: name, account: sample.org, date: date, used: $0, reset: sample.resets?[name == "Sesión" ? "fh" : (name == "Semana" ? "sd" : name)]) } })
    }
    func codex(_ sample: CodexSample) {
        add(sample.windows.map { QuotaPoint(source: "Codex", window: $0.window_minutes == 300 ? "Sesión" : ($0.window_minutes == 10080 ? "Semana" : "\($0.window_minutes) min"), account: nil, date: sample.date, used: $0.used_percent, reset: $0.resets_at) })
    }
    func series(_ source: String, _ window: String, account: String?) -> [QuotaPoint] { points.filter { $0.source == source && $0.window == window && $0.account == account } }
    func rate(_ values: [QuotaPoint]) -> String {
        guard let last = values.last else { return "Sin datos" }
        let cutoff = last.date.addingTimeInterval(-3600)
        let baseline = values.last(where: { $0.date <= cutoff }) ?? values.first!
        let elapsed = last.date.timeIntervalSince(baseline.date)
        guard elapsed >= 60 else { return "Juntando muestras…" }
        let section = values.filter { $0.date >= baseline.date }
        if zip(section, section.dropFirst()).contains(where: { $1.used < $0.used || ($1.reset != nil && $0.reset != nil && $1.reset != $0.reset) }) { return "Cupo reiniciado · no comparable" }
        if elapsed > 4200 { return "Sin muestra cercana a hace 1 h" }
        let delta = last.used - baseline.used
        let prefix = String(format: "+%.1f pp", delta)
        return elapsed >= 3300 ? prefix + " / última hora registrada" : prefix + " / \(Int(elapsed / 60)) min registrados"
    }
}
struct AIConsumptionView: View {
    @ObservedObject var store: UsageHistoryStore
    @ObservedObject var monitor: Monitor
    let showClaude: Bool
    let showCodex: Bool
    var coral: Color { Color(red: 0.82, green: 0.44, blue: 0.32) }
    var blue: Color { Color(red: 0.48, green: 0.57, blue: 0.94) }
    var claude: [QuotaPoint] { store.series("Claude", "Sesión", account: monitor.sample?.org) }
    var codex: [QuotaPoint] { store.series("Codex", "Sesión", account: nil) }
    func hourly(_ points: [QuotaPoint]) -> [Double] {
        let calendar = Calendar.current; let start = calendar.startOfDay(for: Date())
        var hours = [Double](repeating: 0, count: 24)
        for (prior, current) in zip(points, points.dropFirst()) {
            guard current.date >= start, current.used >= prior.used, current.reset == prior.reset, current.date.timeIntervalSince(prior.date) <= 1800 else { continue }
            hours[calendar.component(.hour, from: current.date)] += current.used - prior.used
        }
        return hours
    }
    var body: some View {
        let c = showClaude ? hourly(claude) : [Double](repeating: 0,count: 24)
        let x = showCodex ? hourly(codex) : [Double](repeating: 0,count: 24)
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 14) {
                HStack { Label("Tendencia", systemImage: "chart.bar.fill").font(.headline); Spacer(); Text("Hoy · sesión").font(.caption).foregroundStyle(.gray) }
                HourlyQuotaBars(claude: c, codex: x, coral: coral, blue: blue).frame(height: 82)
                HStack { Text("00 h"); Spacer(); Text("12 h"); Spacer(); Text("23 h") }.font(.system(size: 9)).foregroundStyle(.gray)
                HStack(spacing: 14) {
                    if showClaude { legend("Claude", color: coral) }
                    if showCodex { legend("Codex", color: blue) }
                    Spacer()
                }
            }.padding(16).background(Color(white: 0.065), in: RoundedRectangle(cornerRadius: 24))
            if let error = store.error { Text(error).font(.caption).foregroundStyle(.orange) }
        }
    }
    func legend(_ name: String, color: Color) -> some View { HStack(spacing: 5) { Circle().fill(color).frame(width: 5,height: 5); Text(name).font(.system(size: 10)).foregroundStyle(.gray) } }
}

struct HourlyQuotaBars: View {
    let claude: [Double]; let codex: [Double]; let coral: Color; let blue: Color
    var body: some View {
        let maximum = max(1, zip(claude,codex).map(+).max() ?? 1)
        GeometryReader { geometry in
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(0..<24, id: \.self) { hour in
                    VStack(spacing: 0) {
                        if codex[hour] > 0 { Rectangle().fill(blue).frame(height: geometry.size.height * codex[hour] / maximum) }
                        if claude[hour] > 0 { Rectangle().fill(coral).frame(height: geometry.size.height * claude[hour] / maximum) }
                        if codex[hour] + claude[hour] == 0 { Capsule().fill(Color.white.opacity(0.12)).frame(height: 2) }
                    }.frame(maxWidth: .infinity).clipShape(RoundedRectangle(cornerRadius: 3))
                    .help(String(format: "%02d h · Claude +%.1f pp · Codex +%.1f pp", hour, claude[hour], codex[hour]))
                }
            }.frame(height: geometry.size.height, alignment: .bottom)
        }
    }
}
