import SwiftUI
import AppKit
import CoreAudio
import Darwin

@_silgen_name("mmStart") private func mmStart(_ objects: UnsafePointer<UInt32>, _ count: UInt32, _ output: UInt32, _ gain: Float, _ error: UnsafeMutablePointer<Int32>) -> UnsafeMutableRawPointer?
@_silgen_name("mmHealthy") private func mmHealthy(_ handle: UnsafeMutableRawPointer) -> Bool
@_silgen_name("mmGain") private func mmGain(_ handle: UnsafeMutableRawPointer, _ gain: Float)
@_silgen_name("mmStop") private func mmStop(_ handle: UnsafeMutableRawPointer)
struct MixerApp: Identifiable { let id: String; let name: String; let objects: [UInt32] }
final class MixerModel: ObservableObject {
    @Published var enabled = false
    @Published var apps: [MixerApp] = []
    @Published var gains: [String: Double] = [:]
    @Published var error: String?
    private var engines: [String: UnsafeMutableRawPointer] = [:]
    private var output: UInt32 = 0
    private var timer: Timer?
    private var lastVolumes: [String: Double] = [:]
    init() { timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() } }
    func activate(_ value: Bool) { enabled = value; if value { refresh() } else { stopAll(); apps = [] } }
    func stopAll() { for engine in engines.values { mmStop(engine) }; engines.removeAll(); gains.removeAll() }
    deinit { for engine in engines.values { mmStop(engine) } }
    func read<T>(_ object: UInt32, _ key: AudioObjectPropertySelector, _ initial: T) -> T? {
        var a=AudioObjectPropertyAddress(mSelector:key,mScope:kAudioObjectPropertyScopeGlobal,mElement:0)
        var value=initial; var size=UInt32(MemoryLayout<T>.size)
        let result=withUnsafeMutablePointer(to:&value) { AudioObjectGetPropertyData(object,&a,0,nil,&size,$0) }
        return result == noErr ? value:nil
    }
    func refresh() {
        guard enabled else { return }
        guard #available(macOS 14.2,*) else { error="El mezclador requiere macOS 14.2 o posterior."; return }
        let system=UInt32(kAudioObjectSystemObject)
        let currentOutput=read(system,kAudioHardwarePropertyDefaultOutputDevice,UInt32(0)) ?? 0
        if output != 0 && output != currentOutput { stopAll(); error="Cambió la salida. Los volúmenes por app volvieron al original." }
        output=currentOutput
        var a=AudioObjectPropertyAddress(mSelector:kAudioHardwarePropertyProcessObjectList,mScope:kAudioObjectPropertyScopeGlobal,mElement:0)
        var size:UInt32=0
        guard AudioObjectGetPropertyDataSize(system,&a,0,nil,&size)==noErr else { error="No se pudieron listar las apps de audio."; return }
        var objects=[UInt32](repeating:0,count:Int(size)/4)
        let status=objects.withUnsafeMutableBytes { bytes -> OSStatus in guard let p=bytes.baseAddress,size>0 else { return -1 }; return AudioObjectGetPropertyData(system,&a,0,nil,&size,p) }
        guard status==noErr || size==0 else { error="No se pudieron leer los procesos de audio."; return }
        var groups:[String:(String,[UInt32])]=[:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app.processIdentifier != getpid() && app.bundleIdentifier != "local.mimac.monitor" && !app.isTerminated {
            guard let url = app.bundleURL else { continue }
            groups[url.path] = (app.localizedName ?? url.deletingPathExtension().lastPathComponent, [])
        }
        for object in objects {
            guard let pid=read(object,kAudioProcessPropertyPID,Int32(0)), pid != getpid() else { continue }
            let running = NSRunningApplication(processIdentifier: pid)
            guard running?.isTerminated != true else { continue }
            let bundle = read(object, kAudioProcessPropertyBundleID, "" as CFString) as String? ?? running?.bundleIdentifier ?? ""
            if bundle.hasPrefix("com.apple.audio") || bundle == "local.mimac.monitor" { continue }
            // Audio services (notably Chromium helpers) need not be registered with AppKit.
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            let length = path.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
            let executable = length > 0 ? String(cString: path) : nil
            var root = running?.bundleURL ?? executable.map { URL(fileURLWithPath: $0) }
            if let url = root, let range = url.path.range(of: ".app/") {
                root = URL(fileURLWithPath: String(url.path[..<range.lowerBound]) + ".app")
            }
            if root?.pathExtension != "app" {
                root = NSWorkspace.shared.runningApplications
                    .filter { candidate in
                        guard let id = candidate.bundleIdentifier else { return false }
                        return bundle == id || bundle.hasPrefix(id + ".")
                    }
                    .max { ($0.bundleIdentifier?.count ?? 0) < ($1.bundleIdentifier?.count ?? 0) }?.bundleURL
            }
            guard let root else { continue }
            let id = root.path
            guard groups[id] != nil else { continue }
            let name = root.deletingPathExtension().lastPathComponent
            let old=groups[id] ?? (name,[]); groups[id]=(name,old.1+[object])
        }
        let next=groups.map { MixerApp(id:$0.key,name:$0.value.0,objects:$0.value.1.sorted()) }.sorted { $0.name < $1.name }
        for key in Array(engines.keys) {
            if next.first(where:{$0.id==key})?.objects != apps.first(where:{$0.id==key})?.objects || !next.contains(where:{$0.id==key}) {
                if let engine=engines.removeValue(forKey:key) { mmStop(engine) }
                if !next.contains(where: { $0.id == key }) { gains[key] = nil }
            }
        }
        apps=next
        for app in apps where engines[app.id] == nil && (gains[app.id] ?? 1) < 0.999 && isPlaying(app) {
            set(gains[app.id] ?? 1, for: app)
        }
    }
    private func isPlaying(_ app: MixerApp) -> Bool {
        app.objects.contains { read($0, kAudioProcessPropertyIsRunningOutput, UInt32(0)) == 1 }
    }
    func set(_ value: Double, for app: MixerApp) {
        let gain=min(1,max(0,value)); error=nil
        if gain >= 0.999 {
            if let engine=engines.removeValue(forKey:app.id) { mmStop(engine) }; gains[app.id]=1; return
        }
        if let engine=engines[app.id] { mmGain(engine,Float(gain)); gains[app.id]=gain; return }
        // Keep the requested level until this app creates an audio stream.
        gains[app.id] = gain
        guard !app.objects.isEmpty, isPlaying(app) else { return }
        var status:Int32=0
        let engine=app.objects.withUnsafeBufferPointer { buffer in mmStart(buffer.baseAddress!,UInt32(buffer.count),output,Float(gain),&status) }
        if let engine {
            engines[app.id]=engine; gains[app.id]=gain
            DispatchQueue.main.asyncAfter(deadline:.now()+4) { [weak self] in
                guard let self,self.engines[app.id]==engine else { return }
                if !mmHealthy(engine) && self.isPlaying(app) { self.engines.removeValue(forKey:app.id); mmStop(engine); self.gains[app.id]=1; self.error="No llegó audio compatible de \(app.name). Se restauró su volumen original." }
            }
        }
        else { gains[app.id] = 1; error=status == -70001 ? "Esta salida no es compatible con el mezclador estéreo." : "No se pudo controlar \(app.name) (\(status)). Revisá el permiso de grabación de audio del sistema para Mi Mac." }
    }
    func toggleMute(_ app: MixerApp) {
        let value=gains[app.id] ?? 1
        if value > 0 { lastVolumes[app.id]=value; set(0,for:app) } else { set(lastVolumes[app.id] ?? 1,for:app) }
    }
}
struct MixerVolumeStrip: View {
    let title: String
    let icon: NSImage?
    @Binding var value: Double
    var enabled = true
    var muted = false
    var system = false
    let mute: () -> Void
    var reset: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 10) {
            Group {
                if let icon { Image(nsImage: icon).resizable().scaledToFit() }
                else { Image(systemName: "speaker.wave.2.fill").font(.system(size: 25)).foregroundStyle(.white) }
            }.frame(width: 38, height: 38)
            Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1).help(title)
            GeometryReader { geometry in
                let level = muted ? 0 : min(1, max(0, value))
                ZStack(alignment: .bottom) {
                    Capsule().fill(Color.white.opacity(0.10))
                    Capsule().fill(system ? Color.white.opacity(0.85) : Color.accentColor)
                        .frame(height: geometry.size.height * level)
                }
                .contentShape(Capsule())
                .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    guard enabled else { return }
                    value = min(1, max(0, 1 - drag.location.y / geometry.size.height))
                })
                .accessibilityElement()
                .accessibilityLabel("Volumen de \(title)")
                .accessibilityValue(enabled ? "\(Int(level * 100)) por ciento" : "Control externo")
                .accessibilityAdjustableAction { direction in
                    guard enabled else { return }
                    switch direction {
                    case .increment: value = min(1, value + 0.05)
                    case .decrement: value = max(0, value - 0.05)
                    @unknown default: break
                    }
                }
            }.frame(width: 40, height: 150).opacity(enabled ? 1 : 0.4)
            Text(enabled ? "\(Int(((muted ? 0 : value) * 100).rounded()))%" : "Externo")
                .font(.system(size: 13, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button(action: mute) {
                    Image(systemName: muted || value == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }.disabled(!enabled).help("Silenciar o restaurar \(title)")
                if let reset {
                    Button(action: reset) { Image(systemName: "arrow.counterclockwise") }.help("Restaurar al 100%")
                }
            }.buttonStyle(.plain).font(.system(size: 13)).frame(height: 20)
        }.frame(width: 84)
    }
}

struct MixerView: View {
    @ObservedObject var model: MixerModel
    @ObservedObject var audio: AudioModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Mezclador de volumen").font(.headline)
                Spacer()
                Toggle("Volumen por app", isOn: Binding(get: { model.enabled }, set: model.activate))
                    .labelsHidden().toggleStyle(.switch).help("Activar volumen por app")
            }
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(alignment: .top, spacing: 12) {
                    MixerVolumeStrip(title: "General", icon: nil,
                        value: Binding(get: { audio.volume }, set: { audio.setVolume($0); if audio.muted && audio.canMute { audio.setMute(false) } }),
                        enabled: audio.adjustable, muted: audio.muted, system: true,
                        mute: { if audio.canMute { audio.setMute(!audio.muted) } else { audio.setVolume(audio.volume > 0 ? 0 : 1) } })
                    Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 270)
                    if model.enabled {
                        ForEach(model.apps) { app in
                            MixerVolumeStrip(title: app.name,
                                icon: NSWorkspace.shared.icon(forFile: app.id),
                                value: Binding(get: { model.gains[app.id] ?? 1 }, set: { model.set($0, for: app) }),
                                mute: { model.toggleMute(app) }, reset: { model.set(1, for: app) })
                        }
                    }
                    if !model.enabled || model.apps.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Image(systemName: "waveform").font(.title2)
                            Text(model.enabled ? "Sin apps abiertas" : "Activá el volumen por app")
                                .font(.system(size: 12, weight: .medium))
                            Text(model.enabled ? "Abrí una app para ajustar su volumen." : "Ajustá cada app de forma independiente.")
                                .font(.caption)
                        }.foregroundStyle(.secondary).frame(width: 180, height: 240)
                    }
                }.padding(.vertical, 4)
            }
            if model.enabled && !model.apps.isEmpty {
                Text("Apps abiertas · Si todavía no emiten audio, el volumen se aplicará al reproducir.").font(.caption).foregroundStyle(.secondary)
                Button("Restaurar todos al 100%") { model.stopAll() }.font(.caption).buttonStyle(.plain).foregroundStyle(.secondary)
            }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.orange) }
        }
    }
}
