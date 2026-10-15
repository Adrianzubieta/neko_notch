import Foundation
import CryptoKit

let fm = FileManager.default
let home = ProcessInfo.processInfo.environment["NEKONOTCH_TEST_HOME"].map { URL(fileURLWithPath: $0) } ?? fm.homeDirectoryForCurrentUser
let dataDirectory = home.appendingPathComponent("Library/Application Support/MiMac")
let sampleFile = dataDirectory.appendingPathComponent("claude-code-usage.json")
let configDirectory = home.appendingPathComponent(".claude")
let wrapperConfig = configDirectory.appendingPathComponent("nekonotch-statusline-config.json")
func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
func load(_ url: URL) -> [String: Any]? { (try? Data(contentsOf: url)).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } }
func write(_ object: [String: Any], _ url: URL) throws {
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])
    try data.write(to: url, options: .atomic)
    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}
if CommandLine.arguments.contains("--install") {
    do {
        let settingsFile = configDirectory.appendingPathComponent("settings.json")
        var settings: [String: Any] = [:]
        if fm.fileExists(atPath: settingsFile.path) {
            guard let existing = load(settingsFile) else { throw NSError(domain: "No se pudo leer settings.json; no se modificó.", code: 1) }
            settings = existing
        }
        let destination = configDirectory.appendingPathComponent("nekonotch-statusline")
        let command = shellQuote(destination.path)
        let prior = settings["statusLine"] as? [String: Any]
        let ours = prior?["command"] as? String == command
        if prior != nil && !ours {
            try write(["previous": prior!], wrapperConfig)
        }
        if fm.fileExists(atPath: settingsFile.path) {
            let backup = configDirectory.appendingPathComponent("settings.pre-nekonotch-" + UUID().uuidString + ".json")
            try fm.copyItem(at: settingsFile, to: backup)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        }
        try fm.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        let source = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        if source.path != destination.path {
            let binary = try Data(contentsOf: source)
            try binary.write(to: destination, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.path)
        }
        var line = prior ?? [:]
        line["type"] = "command"; line["command"] = command
        settings["statusLine"] = line
        try write(settings, settingsFile)
        print("Conectado a Claude Code. Los límites llegarán después de una respuesta de Claude Code.")
    } catch { fputs("No se pudo configurar Claude Code. \(error.localizedDescription)\n", stderr); exit(1) }
    exit(0)
}
let input = FileHandle.standardInput.readDataToEndOfFile()
guard let payload = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] else { exit(0) }
var display: [String] = []
if let rate = payload["rate_limits"] as? [String: Any] {
    var usage: [String: Any] = [:]; var resets: [String: Any] = [:]
    let now = Date().timeIntervalSince1970
    for (key, short, label) in [("five_hour", "fh", "5 h"), ("seven_day", "sd", "Semana")] {
        guard let bucket = rate[key] as? [String: Any], let number = bucket["used_percentage"] as? NSNumber else { continue }
        let value = number.doubleValue
        guard value.isFinite, (0...100).contains(value) else { continue }
        if let reset = bucket["resets_at"] as? NSNumber {
            guard reset.doubleValue > now else { continue }
            resets[short] = reset
        }
        usage[short] = value; display.append("\(label): \(Int(value.rounded()))%")
    }
    let cost = payload["cost"] as? [String: Any] ?? [:]
    let context = payload["context_window"] as? [String: Any] ?? [:]
    let signature: [String: Any] = ["u": usage, "resets": resets, "session": payload["session_id"] ?? "", "api_ms": cost["total_api_duration_ms"] ?? 0, "input_tokens": context["total_input_tokens"] ?? 0, "output_tokens": context["total_output_tokens"] ?? 0]
    if let data = try? JSONSerialization.data(withJSONObject: signature, options: .sortedKeys) {
        let fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if load(sampleFile)?["fingerprint"] as? String != fingerprint {
            try? write(["t": now * 1000, "org": "claude-code", "u": usage, "resets": resets, "fingerprint": fingerprint], sampleFile)
        }
    }
}
if let previous = load(wrapperConfig)?["previous"] as? [String: Any], let command = previous["command"] as? String, !command.contains("nekonotch-statusline") {
    let process = Process(); let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = ["-c", command]
    process.standardInput = pipe; process.standardOutput = FileHandle.standardOutput; process.standardError = FileHandle.standardError
    do { try process.run(); try pipe.fileHandleForWriting.write(contentsOf: input); try pipe.fileHandleForWriting.close(); process.waitUntilExit() } catch {}
} else { print(display.isEmpty ? "Claude Code" : "Claude · " + display.joined(separator: " · ")) }
