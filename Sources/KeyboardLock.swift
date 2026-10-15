import SwiftUI
import AppKit
import ApplicationServices

final class KeyboardLock: ObservableObject {
    @Published private(set) var locked = false
    @Published private(set) var error: String?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    func setLocked(_ value: Bool) {
        if !value { unlock(); return }
        guard !locked else { return }
        guard AXIsProcessTrusted() else {
            error = "Permití NekoNotch en Ajustes del Sistema → Privacidad y seguridad → Accesibilidad. Después volvé a tocar el botón."
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            return
        }
        let mask = [CGEventType.keyDown, .keyUp, .flagsChanged].reduce(CGEventMask(1) << 14) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, context in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let context {
                    let model = Unmanaged<KeyboardLock>.fromOpaque(context).takeUnretainedValue()
                    DispatchQueue.main.async { model.unlock(); model.error = "macOS interrumpió el bloqueo. El teclado volvió a activarse." }
                }
            }
            // System-defined events also include non-keyboard messages; only swallow media keys.
            if type.rawValue == 14 && NSEvent(cgEvent: event)?.subtype.rawValue != 8 {
                return Unmanaged.passUnretained(event)
            }
            // Discard key events without inspecting or storing their contents.
            return nil
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            error = "No se pudo bloquear el teclado. Revisá el permiso de Accesibilidad de NekoNotch."
            return
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            error = "No se pudo iniciar el bloqueo del teclado."
            return
        }
        self.tap = tap; self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        locked = true; error = nil
    }
    func unlock() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil; locked = false
    }
    deinit {
        if let tap { CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    }
}

struct KeyboardFloatingButton: View {
    @ObservedObject var model: KeyboardLock
    var body: some View {
        Button { model.setLocked(!model.locked) } label: {
            Image(systemName: model.locked ? "keyboard.badge.eye" : "keyboard")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(model.locked ? .orange : .white)
                .frame(width: 44, height: 44).background(.black, in: Circle())
                .overlay(Circle().stroke(model.locked ? Color.orange : Color.white.opacity(0.55), lineWidth: 1))
        }.buttonStyle(.plain)
            .help(model.error ?? (model.locked ? "Activar teclado" : "Bloquear teclado · el mouse sigue activo"))
            .accessibilityLabel(model.locked ? "Activar teclado" : "Bloquear teclado")
    }
}
struct KeyboardOptions: View {
    @ObservedObject var model: KeyboardLock
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Bloquear teclado", isOn: Binding(get: { model.locked }, set: model.setLocked))
            Text("El mouse y el trackpad siguen activos. Tocá el botón otra vez o usá el menú del gatito para desbloquear.").font(.caption).foregroundStyle(.secondary)
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.orange) }
        }
    }
}
struct KeyboardMenuAction: View {
    @ObservedObject var model: KeyboardLock
    var body: some View {
        Button(model.locked ? "Activar teclado" : "Bloquear teclado") { model.setLocked(!model.locked) }
    }
}
