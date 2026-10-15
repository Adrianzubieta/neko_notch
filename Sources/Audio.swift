import SwiftUI
import CoreAudio

struct SoundOutput: Identifiable { let id: AudioDeviceID; let name: String }
final class AudioModel: ObservableObject {
    @Published var outputs: [SoundOutput] = []
    @Published var selected: AudioDeviceID = 0
    @Published var volume = 0.0
    @Published var muted = false
    @Published var adjustable = false
    @Published var canMute = false
    @Published var error: String?
    private var channels: [UInt32] = []
    private var timer: Timer?
    func address(_ key: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput, channel: UInt32 = 0) -> AudioObjectPropertyAddress { AudioObjectPropertyAddress(mSelector: key, mScope: scope, mElement: channel) }
    func read<T>(_ object: AudioObjectID, _ property: AudioObjectPropertyAddress, _ initial: T) -> T? {
        var a = property; var value = initial; var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &a, 0, nil, &size, $0) }
        return status == noErr ? value : nil
    }
    func writable(_ property: AudioObjectPropertyAddress) -> Bool { var a = property; var result = DarwinBoolean(false); return AudioObjectIsPropertySettable(selected, &a, &result) == noErr && result.boolValue }
    @discardableResult func write<T>(_ object: AudioObjectID, _ property: AudioObjectPropertyAddress, _ value: T) -> Bool { var a = property; var value = value; return withUnsafePointer(to: &value) { AudioObjectSetPropertyData(object, &a, 0, nil, UInt32(MemoryLayout<T>.size), $0) } == noErr }
    init() { refresh(); timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() } }
    func refresh() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var a = address(kAudioHardwarePropertyDevices, scope: kAudioObjectPropertyScopeGlobal); var size: UInt32 = 0
        if AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size) == noErr {
            var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
            let result = devices.withUnsafeMutableBytes { buffer -> OSStatus in
                guard let base = buffer.baseAddress, size > 0 else { return -1 }
                return AudioObjectGetPropertyData(system, &a, 0, nil, &size, base)
            }
            if result == noErr {
                outputs = devices.compactMap { id in
                    var streams = self.address(kAudioDevicePropertyStreams); var length: UInt32 = 0
                    guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &length) == noErr, length > 0 else { return nil }
                    let name = self.read(id, self.address(kAudioObjectPropertyName, scope: kAudioObjectPropertyScopeGlobal), "Audio" as CFString) as String? ?? "Audio"
                    return SoundOutput(id: id, name: name)
                }.sorted { $0.name < $1.name }
            }
        }
        selected = read(system, address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal), AudioDeviceID(0)) ?? 0
        channels = [0].filter { writable(address(kAudioDevicePropertyVolumeScalar, channel: $0)) }
        if channels.isEmpty { channels = [1,2].filter { writable(address(kAudioDevicePropertyVolumeScalar, channel: $0)) } }
        let values = channels.compactMap { read(selected, address(kAudioDevicePropertyVolumeScalar, channel: $0), Float32(0)) }
        adjustable = !values.isEmpty
        if adjustable { volume = Double(values.reduce(0,+)) / Double(values.count) }
        canMute = writable(address(kAudioDevicePropertyMute))
        muted = read(selected, address(kAudioDevicePropertyMute), UInt32(0)) == 1
    }
    func select(_ device: AudioDeviceID) {
        if write(AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal), device) { error = nil; refresh() }
        else { error = "No se pudo cambiar la salida." }
    }
    func setVolume(_ value: Double) {
        guard adjustable else { return }
        var success = true
        for channel in channels { if !write(selected, address(kAudioDevicePropertyVolumeScalar, channel: channel), Float32(min(1,max(0,value)))) { success = false } }
        if success { volume = value; error = nil } else { error = "No se pudo ajustar el volumen."; refresh() }
    }
    func setMute(_ value: Bool) {
        if write(selected, address(kAudioDevicePropertyMute), UInt32(value ? 1 : 0)) { muted = value; error = nil }
        else { error = "Esta salida no permite silenciar desde macOS." }
    }
}
struct AudioView: View {
    @ObservedObject var model: AudioModel
    @ObservedObject var mixer: MixerModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "hifispeaker.fill").foregroundStyle(.secondary)
                Picker("Salida de sonido", selection: Binding(get: { model.selected }, set: model.select)) {
                    ForEach(model.outputs) { device in Text(device.name).tag(device.id) }
                }.labelsHidden()
            }
            if model.outputs.isEmpty { Text("No se encontraron salidas de audio.").font(.caption).foregroundStyle(.secondary) }
            MixerView(model: mixer, audio: model)
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.orange) }
        }.padding(16).background(Color(white: 0.065), in: RoundedRectangle(cornerRadius: 20))
    }
}
