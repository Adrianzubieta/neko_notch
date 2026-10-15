import SwiftUI
import AppKit
import IOKit.ps
import IOKit.pwr_mgt
import Darwin
import SystemConfiguration

final class KeepAwake: ObservableObject {
    @Published private(set) var enabled = false
    @Published var error: String?
    private var assertion: IOPMAssertionID = 0
    func setEnabled(_ value: Bool) {
        guard value != enabled else { return }
        if value {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "Mi Mac · Mantener pantalla encendida" as CFString, &id)
            guard result == kIOReturnSuccess else { error = "No se pudo mantener la pantalla encendida (\(result))."; return }
            assertion = id; enabled = true; error = nil
        } else {
            let result = IOPMAssertionRelease(assertion)
            guard result == kIOReturnSuccess else { error = "No se pudo desactivar (\(result)). Intentá nuevamente o cerrá Mi Mac."; return }
            assertion = 0; enabled = false; error = nil
        }
    }
    deinit { if enabled { IOPMAssertionRelease(assertion) } }
}

final class MacStatus: ObservableObject {
    @Published var cpu: Double?; @Published var systemCPU = 0.0; @Published var userCPU = 0.0; @Published var idleCPU = 100.0
    @Published var cpuHistory: [Double] = []
    @Published var memoryPercent = 0.0; @Published var appMemory: UInt64 = 0; @Published var wiredMemory: UInt64 = 0; @Published var compressedMemory: UInt64 = 0
    @Published var pressure = "No disponible"
    @Published var diskPercent = 0.0; @Published var diskUsed: Int64 = 0; @Published var diskTotal: Int64 = 0
    @Published var battery = "Sin batería"; @Published var powerSource = "No disponible"; @Published var health = "No disponible"; @Published var cycles = "No disponible"
    @Published var network = "Sin conexión"; @Published var ip = "No disponible"; @Published var upload = "—"; @Published var download = "—"
    private var previousCPU: [UInt64]?
    private var previousNetwork: (String, UInt64, UInt64, Date)?
    private var timer: Timer?
    init() { refresh(); timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() } }
    func refresh() {
        var ticks = host_cpu_load_info(); var cpuCount = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let cpuResult = withUnsafeMutablePointer(to: &ticks) { p in p.withMemoryRebound(to: integer_t.self, capacity: Int(cpuCount)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &cpuCount) } }
        if cpuResult == KERN_SUCCESS {
            let current = [UInt64(ticks.cpu_ticks.0), UInt64(ticks.cpu_ticks.1), UInt64(ticks.cpu_ticks.2), UInt64(ticks.cpu_ticks.3)]
            if let previous = previousCPU, zip(current, previous).allSatisfy({ $0 >= $1 }) {
                let delta = zip(current, previous).map { $0 - $1 }; let total = Double(delta.reduce(0,+))
                if total > 0 { userCPU = Double(delta[0] + delta[3]) / total * 100; systemCPU = Double(delta[1]) / total * 100; idleCPU = Double(delta[2]) / total * 100; cpu = userCPU + systemCPU; cpuHistory.append(cpu!); cpuHistory = Array(cpuHistory.suffix(60)) }
            }
            previousCPU = current
        }
        var stats = vm_statistics64(); var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { ptr in ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) } }
        if result == KERN_SUCCESS {
            let page = UInt64(vm_kernel_page_size)
            appMemory = UInt64(max(0, Int64(stats.internal_page_count) - Int64(stats.purgeable_count))) * page
            wiredMemory = UInt64(stats.wire_count) * page; compressedMemory = UInt64(stats.compressor_page_count) * page
            memoryPercent = min(100, Double(appMemory + wiredMemory + compressedMemory) / Double(ProcessInfo.processInfo.physicalMemory) * 100)
        }
        var level: Int32 = 0; var length = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &length, nil, 0) == 0 { pressure = level == 1 ? "Normal" : (level == 2 ? "Elevada" : (level == 4 ? "Crítica" : "No disponible")) }
        if let d = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()), let free = d[.systemFreeSize] as? NSNumber, let total = d[.systemSize] as? NSNumber { diskTotal = total.int64Value; diskUsed = max(0, diskTotal - free.int64Value); diskPercent = diskTotal > 0 ? Double(diskUsed) / Double(diskTotal) * 100 : 0 }
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(), let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for source in sources {
                if let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any], let current = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 {
                    battery = "\(current * 100 / max)%"; powerSource = d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue ? "Cargador" : "Batería"
                    if d[kIOPSIsChargingKey] as? Bool == true { powerSource += " · Cargando" }
                }
            }
        }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if service != 0 {
            defer { IOObjectRelease(service) }
            func number(_ key: String) -> Double? { (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.doubleValue }
            if let value = number("CycleCount") { cycles = "\(Int(value))" }
            if let capacity = number("AppleRawMaxCapacity"), let design = number("DesignCapacity"), design > 0 { health = String(format: "%.0f%%", min(100, capacity / design * 100)) }
        }
        refreshNetwork()
    }
    func refreshNetwork() {
        let store = SCDynamicStoreCreate(nil, "MiMac" as CFString, nil, nil)
        guard let d = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any], let interface = d["PrimaryInterface"] as? String else { network = "Sin conexión IPv4"; ip = "No disponible"; upload = "—"; download = "—"; previousNetwork = nil; return }
        network = interface
        if let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface], let match = interfaces.first(where: { SCNetworkInterfaceGetBSDName($0) as String? == interface }) { network = SCNetworkInterfaceGetLocalizedDisplayName(match) as String? ?? interface }
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return }
        defer { freeifaddrs(addresses) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        var received: UInt64?; var sent: UInt64?
        while let item = cursor {
            let entry = item.pointee; cursor = entry.ifa_next
            guard String(cString: entry.ifa_name) == interface, let address = entry.ifa_addr else { continue }
            if Int32(address.pointee.sa_family) == AF_INET {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 { ip = String(cString: buffer) }
            }
            if Int32(address.pointee.sa_family) == AF_LINK, let data = entry.ifa_data {
                let stats = data.assumingMemoryBound(to: if_data.self).pointee; received = UInt64(stats.ifi_ibytes); sent = UInt64(stats.ifi_obytes)
            }
        }
        if let received, let sent {
            let now = Date()
            if let previous = previousNetwork, previous.0 == interface, received >= previous.1, sent >= previous.2 {
                let seconds = now.timeIntervalSince(previous.3)
                if seconds > 0 { download = speed(Double(received - previous.1) / seconds); upload = speed(Double(sent - previous.2) / seconds) }
            } else { download = "Midiendo…"; upload = "Midiendo…" }
            previousNetwork = (interface, received, sent, now)
        }
    }
    func speed(_ bytes: Double) -> String { bytes >= 1_000_000 ? String(format: "%.1f MB/s", bytes / 1_000_000) : String(format: "%.1f kB/s", bytes / 1000) }
}
struct MacStatusView: View {
    @ObservedObject var model: MacStatus
    @ObservedObject var awake: KeepAwake
    func percent(_ value: Double) -> String { String(format: "%.1f%%", value) }
    func bytes(_ value: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            block("CPU: \(model.cpu.map(percent) ?? "Midiendo…")", icon: "cpu") {
                detail("Sistema", percent(model.systemCPU)); detail("Usuario", percent(model.userCPU)); detail("Inactivo", percent(model.idleCPU))
                CPUHistoryView(values: model.cpuHistory).frame(height: 26).padding(.top, 3)
            }
            Divider()
            block("Memoria: \(percent(model.memoryPercent))", icon: "memorychip") {
                detail("Presión", model.pressure); detail("Apps (aprox.)", bytes(model.appMemory)); detail("Física reservada", bytes(model.wiredMemory)); detail("Comprimida", bytes(model.compressedMemory))
            }
            Divider()
            block("Almacenamiento: \(percent(model.diskPercent)) usado", icon: "internaldrive") {
                Text("\(ByteCountFormatter.string(fromByteCount: model.diskUsed, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: model.diskTotal, countStyle: .file))").font(.caption).foregroundStyle(.gray)
                ProgressView(value: model.diskPercent, total: 100).tint(.blue)
            }
            Divider()
            block("Batería: \(model.battery)", icon: "battery.100") {
                detail("Fuente de energía", model.powerSource); detail("Capacidad máxima (est.)", model.health); detail("Ciclos", model.cycles)
            }
            Divider()
            block("Red: \(model.network)", icon: "network") {
                detail("IP local", model.ip); detail("Carga", model.upload); detail("Descarga", model.download)
            }
        }.padding(16).background(Color(white: 0.065), in: RoundedRectangle(cornerRadius: 20))
    }
    func block<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: icon).font(.system(size: 27)).foregroundStyle(.gray).frame(width: 34)
            VStack(alignment: .leading, spacing: 5) { Text(title).font(.system(size: 15, weight: .semibold)); content() }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    func detail(_ name: String, _ value: String) -> some View { HStack { Text(name + ":").foregroundStyle(.gray); Text(value).monospacedDigit() }.font(.system(size: 12)) }
}
struct CPUHistoryView: View {
    let values: [Double]
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                let points = values.enumerated().map { index, value in CGPoint(x: geometry.size.width * CGFloat(index) / CGFloat(max(59, values.count - 1)), y: geometry.size.height * (1 - CGFloat(value) / 100)) }
                guard let first = points.first, let last = points.last else { return }
                path.move(to: CGPoint(x: first.x, y: geometry.size.height)); points.forEach { path.addLine(to: $0) }; path.addLine(to: CGPoint(x: last.x, y: geometry.size.height)); path.closeSubpath()
            }.fill(Color.blue.opacity(0.85))
            Rectangle().fill(Color.blue.opacity(0.25)).frame(height: 1).frame(maxHeight: .infinity, alignment: .bottom)
        }
    }
}

final class MusicModel: ObservableObject {
    @Published var title = "Buscando reproducción…"
    @Published var artist = ""
    @Published var artwork: NSImage?
    @Published var source = "macOS"
    @Published var playing = false
    @Published var hasMedia = false
    @Published var sending = false
    @Published var prohibitsSkip = false
    @Published var duration = 0.0
    @Published var elapsed = 0.0
    @Published var sampledAt = Date()
    func position(at date: Date) -> Double {
        min(duration, max(0, elapsed + (playing ? date.timeIntervalSince(sampledAt) : 0)))
    }
    func seek(_ seconds: Double) {
        guard duration > 0 else { return }
        perform("seek", argument: String(Int(min(duration, max(0, seconds)) * 1_000_000)))
    }
    @Published var commandError: String?
    @Published var message = "Lectura automática de Ahora suena"
    private let queue = DispatchQueue(label: "mimac.nowplaying")
    private var timer: Timer?
    private var reading = false
    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.refresh() }
    }
    func send(_ command: Int) {
        guard [2, 4, 5].contains(command) else { return }
        perform("send", argument: String(command))
    }
    private func perform(_ action: String, argument: String) {
        guard hasMedia, !sending,
              let script = Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl"),
              let framework = Bundle.main.privateFrameworksURL?.appendingPathComponent("MediaRemoteAdapter.framework") else { return }
        sending = true; commandError = nil
        queue.async { [weak self] in
            let process = Process(); let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            process.arguments = [script.path, framework.path, action, argument]
            process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = output
            do {
                try process.run()
                let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 8, execute: timeout)
                _ = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit(); timeout.cancel()
                let status = process.terminationStatus
                DispatchQueue.main.async {
                    guard let self else { return }; self.sending = false
                    if status != 0 { self.commandError = "El reproductor no aceptó el comando." }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.refresh() }
                }
            } catch {
                DispatchQueue.main.async { self?.sending = false; self?.commandError = "No se pudo enviar el comando." }
            }
        }
    }
    func refresh() {
        guard !reading, !sending else { return }
        guard let script = Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl"),
              let frameworks = Bundle.main.privateFrameworksURL else {
            title = "Adaptador no disponible"; message = "No se encontró el adaptador de Ahora suena."; return
        }
        reading = true
        let framework = frameworks.appendingPathComponent("MediaRemoteAdapter.framework")
        queue.async { [weak self] in
            let process = Process(); let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            process.arguments = [script.path, framework.path, "get", "--now"]
            process.standardOutput = output; process.standardError = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
            do {
                try process.run()
                let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 8, execute: deadline)
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit(); deadline.cancel()
                let status = process.terminationStatus
                let json = (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? [String: Any]
                DispatchQueue.main.async {
                    guard let self else { return }; self.reading = false
                    if status != 0 {
                        self.artwork = nil; self.hasMedia = false; self.title = "No se pudo consultar Ahora suena"; self.artist = ""; self.source = "macOS"; self.playing = false
                        self.message = "El adaptador no respondió correctamente. Volvé a intentar."; return
                    }
                    guard let json, let title = json["title"] as? String, !title.isEmpty else {
                        self.artwork = nil; self.hasMedia = false; self.title = "Sin reproducción detectada"; self.artist = ""; self.source = "macOS"; self.playing = false
                        self.message = "Mostrará lo que las apps y el navegador compartan con Ahora suena de macOS."; return
                    }
                    let bundleID = json["parentApplicationBundleIdentifier"] as? String ?? json["bundleIdentifier"] as? String
                    let name = bundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.map { url in
                        Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? url.deletingPathExtension().lastPathComponent
                    } ?? bundleID ?? "macOS"
                    self.duration = max(0, json["duration"] as? Double ?? 0)
                    self.elapsed = max(0, json["elapsedTimeNow"] as? Double ?? json["elapsedTime"] as? Double ?? 0)
                    self.sampledAt = Date()
                    self.prohibitsSkip = json["prohibitsSkip"] as? Bool ?? false
                    self.artwork = (json["artworkData"] as? String).flatMap { Data(base64Encoded: $0) }.flatMap { NSImage(data: $0) }
                    self.hasMedia = true; self.title = title; self.artist = json["artist"] as? String ?? ""; self.source = name
                    self.playing = json["playing"] as? Bool ?? false
                    self.message = "Información local de macOS · se revisa cada 3 segundos"
                }
            } catch {
                DispatchQueue.main.async {
                    self?.reading = false; self?.hasMedia = false; self?.title = "No se pudo iniciar la detección"; self?.artist = ""; self?.message = error.localizedDescription
                }
            }
        }
    }
}
struct MusicView: View {
    @ObservedObject var model: MusicModel
    @ObservedObject var audio: AudioModel
    let size: Int
    private var preset: Int { min(2, max(0, size)) }
    private func metric(_ compact: CGFloat, _ normal: CGFloat, _ large: CGFloat) -> CGFloat { [compact, normal, large][preset] }
    private var coverSize: CGFloat { metric(80, 112, 160) }
    var body: some View {
        VStack(alignment: .leading, spacing: metric(8, 12, 18)) {
            HStack {
                Text("Ahora suena").font(.system(size: metric(13, 15, 18), weight: .semibold))
                Spacer()
                Text(model.source).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Image(systemName: model.playing ? "waveform" : "pause.fill")
                    .foregroundStyle(model.playing ? Color.green : Color.gray)
            }
            HStack(alignment: .center, spacing: metric(12, 18, 24)) {
                VStack(spacing: metric(4, 8, 16)) {
                    Group {
                        if let artwork = model.artwork { Image(nsImage: artwork).resizable().scaledToFill() }
                        else {
                            ZStack {
                                LinearGradient(colors: [.teal.opacity(0.5), .black], startPoint: .topLeading, endPoint: .bottomTrailing)
                                Image(systemName: "music.note").font(.system(size: 38)).foregroundStyle(.white.opacity(0.7))
                            }
                        }
                    }.frame(width: coverSize, height: coverSize)
                        .clipShape(RoundedRectangle(cornerRadius: metric(16, 22, 32)))
                        .overlay(RoundedRectangle(cornerRadius: metric(16, 22, 32)).stroke(.white.opacity(0.1)))
                        .shadow(color: .teal.opacity(model.playing ? 0.18 : 0), radius: 20)
                    HStack(spacing: 8) {
                        Image(systemName: audio.muted ? "speaker.slash.fill" : "speaker.wave.2.fill").font(.caption)
                        Slider(value: Binding(get: { audio.volume }, set: { audio.setVolume($0); if audio.muted && audio.canMute { audio.setMute(false) } }), in: 0...1)
                            .disabled(!audio.adjustable).tint(.white).accessibilityLabel("Volumen general")
                    }.frame(width: coverSize)
                }
                VStack(alignment: .leading, spacing: metric(4, 6, 8)) {
                    Text(model.title).font(.system(size: metric(15, 19, 25), weight: .semibold)).lineLimit(2).help(model.title)
                    if !model.artist.isEmpty { Text(model.artist).font(.system(size: metric(11, 13, 15))).foregroundStyle(.secondary).lineLimit(1) }
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        VStack(spacing: 6) {
                            GeometryReader { geometry in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(.white.opacity(0.12))
                                    Capsule().fill(.white.opacity(0.9)).frame(width: geometry.size.width * (model.duration > 0 ? model.position(at: context.date) / model.duration : 0))
                                }.contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 0).onEnded { drag in
                                    guard model.hasMedia, model.duration > 0 else { return }
                                    model.seek(model.duration * min(1, max(0, drag.location.x / geometry.size.width)))
                                })
                            }.frame(height: 7).accessibilityLabel("Progreso de reproducción")
                            HStack {
                                Text(model.duration > 0 ? time(model.position(at: context.date)) : "—:—")
                                Spacer()
                                Text(model.duration > 0 ? "−" + time(model.duration - model.position(at: context.date)) : "—:—")
                            }.font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }.padding(.top, metric(4, 6, 10))
                    controls.frame(maxWidth: .infinity).padding(.top, metric(4, 6, 10))
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if !model.hasMedia { Text(model.message).font(.caption).foregroundStyle(.secondary) }
            if let error = model.commandError { Text(error).font(.caption).foregroundStyle(.orange) }
        }.padding(metric(10, 14, 20)).frame(maxWidth: .infinity)
            .background(Color(white: 0.045), in: RoundedRectangle(cornerRadius: 24))
    }
    func time(_ seconds: Double) -> String {
        let value = Int(max(0, seconds))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
    var controls: some View {
        HStack(spacing: metric(10, 18, 24)) {
            control("backward.end.fill", title: "Anterior", command: 5).disabled(model.prohibitsSkip)
            Button { model.send(2) } label: {
                Image(systemName: model.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: metric(15, 19, 24), weight: .semibold)).foregroundStyle(.black)
                    .frame(width: metric(32, 44, 60), height: metric(32, 44, 60)).background(.white, in: Circle())
            }.help(model.playing ? "Pausar" : "Reproducir").accessibilityLabel(model.playing ? "Pausar" : "Reproducir")
            control("forward.end.fill", title: "Siguiente", command: 4).disabled(model.prohibitsSkip)
        }.buttonStyle(.plain).disabled(!model.hasMedia || model.sending).opacity(model.hasMedia ? 1 : 0.35)
    }
    func control(_ icon: String, title: String, command: Int) -> some View {
        Button { model.send(command) } label: {
            Image(systemName: icon).font(.system(size: metric(14, 17, 20))).foregroundStyle(.white.opacity(0.85)).frame(width: metric(24, 28, 30), height: metric(28, 32, 36))
        }.help(title).accessibilityLabel(title)
    }
}

struct BrewPackage: Identifiable {
    let name: String; let version: String; let cask: Bool; let outdated: Bool
    var id: String { "\(cask)-\(name)" }
}
final class BrewModel: ObservableObject {
    @Published var packages: [BrewPackage] = []
    @Published var busy = false
    @Published var message = "Sin consultar"
    @Published var search = ""
    @Published var onlyOutdated = false
    @Published var pending: BrewPackage?
    @Published var action = ""
    let queue = DispatchQueue(label: "mimac.brew")
    var executable: String? { ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) } }
    func run(_ arguments: [String]) -> (Int32, String) {
        guard let executable else { return (1, "Homebrew no está instalado.") }
        let process = Process(); let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        environment["HOMEBREW_NO_ANALYTICS"] = "1"
        process.environment = environment; process.standardInput = FileHandle.nullDevice; process.standardOutput = pipe
        process.standardError = arguments.contains("--json=v2") ? FileHandle.nullDevice : pipe
        do { try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit(); return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "") }
        catch { return (1, error.localizedDescription) }
    }
    func refresh(updateCatalog: Bool = false) {
        guard !busy else { return }; busy = true; message = updateCatalog ? "Buscando actualizaciones…" : "Leyendo paquetes…"
        queue.async { [weak self] in
            guard let self else { return }
            if updateCatalog {
                let update = self.run(["update"])
                if update.0 != 0 { DispatchQueue.main.async { self.busy = false; self.message = "No se pudo actualizar el catálogo: " + String(update.1.suffix(2500)) }; return }
            }
            let result = self.run(["info", "--json=v2", "--installed"])
            var items: [BrewPackage] = []
            if let data = result.1.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                for f in json["formulae"] as? [[String: Any]] ?? [] {
                    guard let name = f["name"] as? String else { continue }
                    let installed = f["installed"] as? [[String: Any]] ?? []
                    items.append(BrewPackage(name: name, version: installed.compactMap { $0["version"] as? String }.joined(separator: ", "), cask: false, outdated: f["outdated"] as? Bool ?? false))
                }
                for c in json["casks"] as? [[String: Any]] ?? [] {
                    guard let name = c["token"] as? String else { continue }
                    items.append(BrewPackage(name: name, version: c["installed"] as? String ?? "Instalado", cask: true, outdated: c["outdated"] as? Bool ?? false))
                }
            }
            let success = result.0 == 0 && result.1.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) } != nil
            DispatchQueue.main.async { self.busy = false; if success { self.packages = items.sorted { $0.name < $1.name }; self.message = "\(items.count) instalados · \(items.filter(\.outdated).count) con actualización" } else { self.message = "No se pudieron leer los paquetes. " + String(result.1.suffix(2000)) } }
        }
    }
    func perform(_ action: String, package: BrewPackage) {
        guard !busy else { return }; busy = true; message = "\(action == "upgrade" ? "Actualizando" : "Desinstalando") \(package.name)…"
        queue.async { [weak self] in
            guard let self else { return }
            let result = self.run([action, package.cask ? "--cask" : "--formula", package.name])
            DispatchQueue.main.async {
                self.busy = false
                if result.0 == 0 { self.refresh() }
                else { self.message = "Homebrew terminó con un error: " + String(result.1.suffix(3000)) }
            }
        }
    }
}
struct BrewView: View {
    @ObservedObject var model: BrewModel
    var filtered: [BrewPackage] { model.packages.filter { (!model.onlyOutdated || $0.outdated) && (model.search.isEmpty || $0.name.localizedCaseInsensitiveContains(model.search)) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Button("Leer paquetes") { model.refresh() }; Button("Buscar actualizaciones") { model.refresh(updateCatalog: true) }; if model.busy { ProgressView().controlSize(.small) } }.disabled(model.busy)
            Text(model.message).font(.caption).foregroundStyle(.gray).textSelection(.enabled)
            TextField("Buscar paquete", text: $model.search).textFieldStyle(.roundedBorder)
            Toggle("Solo con actualización", isOn: $model.onlyOutdated).font(.caption)
            ForEach(filtered) { package in
                HStack {
                    VStack(alignment: .leading, spacing: 3) { Text(package.name).font(.system(size: 13, weight: .medium)); Text("\(package.cask ? "App" : "Fórmula") · \(package.version)").font(.caption2).foregroundStyle(.gray) }
                    Spacer()
                    if package.outdated { Button("Actualizar") { model.action = "upgrade"; model.pending = package } }
                    Button { model.action = "uninstall"; model.pending = package } label: { Image(systemName: "trash") }.help("Desinstalar")
                }.disabled(model.busy).padding(10).background(Color(white: 0.09), in: RoundedRectangle(cornerRadius: 10))
            }
        }.alert(model.action == "upgrade" ? "Actualizar paquete" : "Desinstalar paquete", isPresented: Binding(get: { model.pending != nil }, set: { if !$0 { model.pending = nil } })) {
            if let package = model.pending { Button(model.action == "upgrade" ? "Actualizar" : "Desinstalar", role: model.action == "uninstall" ? .destructive : nil) { model.perform(model.action, package: package); model.pending = nil } }
            Button("Cancelar", role: .cancel) { model.pending = nil }
        } message: { Text("\(model.pending?.name ?? "")\n\(model.action == "upgrade" ? "Homebrew actualizará este paquete y las dependencias que necesite." : "Se eliminará de Homebrew. No se usa --zap ni se fuerzan dependencias.")") }
    }
}
