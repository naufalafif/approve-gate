import AppKit
import BarCore
import Foundation

/// The approve to run: the root-owned copy when installed (see approveCandidates).
func approveBinary() -> String? {
    approveCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
}

/// Runs approve with arguments and optional input, off the main thread. Returns exit code and output.
func approve(_ args: [String], input: String? = nil) async -> (code: Int32, out: String) {
    await Task.detached(priority: .userInitiated) {
        guard let bin = approveBinary() else { return (127, "approve is not installed") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        let out = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = inp
        guard (try? p.run()) != nil else { return (126, "could not run approve") }
        if let input { inp.fileHandleForWriting.write(Data((input + "\n").utf8)) }
        try? inp.fileHandleForWriting.close()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }.value
}

/// Settings the window edits: the rules file, staged until Save.
@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    @Published private(set) var saved: RulesDoc?
    @Published var draft: RulesDoc?
    @Published private(set) var rulesPath = ""
    @Published private(set) var systemMode = false
    @Published private(set) var loadError: String?
    @Published private(set) var saving = false
    @Published var saveMessage: String?
    @Published private(set) var installed: [String: String] = [:]   // CLI name → path, for templates

    var dirty: Bool { draft != nil && draft != saved }

    func load() async {
        let (code, out) = await approve(["status", "--json"])
        guard code == 0, let data = out.data(using: .utf8),
              let s = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = s["rulesPath"] as? String else {
            loadError = "Could not read approve status. Run approve setup."
            return
        }
        rulesPath = path
        systemMode = (s["mode"] as? String) == "system"
        guard let d = FileManager.default.contents(atPath: path), let r = try? JSONDecoder().decode(RulesDoc.self, from: d) else {
            loadError = "Could not read the rules at \(path)."
            return
        }
        loadError = nil
        if saved != r || draft == nil || !dirty { saved = r; draft = r }
        await detectInstalled()
    }

    func revert() { draft = saved; saveMessage = nil }

    /// Saves the draft. System mode: approve installs it after Touch ID or the phone (the settings
    /// helper), or through the macOS admin prompt when the helper is not installed.
    /// Then links any newly added CLIs.
    func save() async {
        guard let draft else { return }
        saving = true
        defer { saving = false }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("approve-rules-\(UUID().uuidString).json")
        do { try draft.encoded().write(to: tmp) } catch { saveMessage = "Could not prepare the rules: \(error.localizedDescription)"; return }
        defer { try? FileManager.default.removeItem(at: tmp) }
        if systemMode {
            let (code, out) = await approve(["rules", "install", tmp.path])
            guard code == 0 else {
                saveMessage = out.contains("declined") ? "Not saved: declined."
                    : out.contains("no answer") ? "Not saved: no answer in time."
                    : out.contains("-128") ? "Not saved: the admin prompt was cancelled." : "Not saved: \(lastLine(out))"
                return
            }
        } else {
            do { try draft.encoded().write(to: URL(fileURLWithPath: rulesPath)) } catch {
                saveMessage = "Not saved: \(error.localizedDescription)"; return
            }
        }
        _ = await approve(["link"])
        saved = draft
        saveMessage = "Saved."
        await Monitor.shared.refresh()
    }

    /// Which template CLIs exist on this Mac, as a login shell finds them.
    func detectInstalled() async {
        let names = templates.map(\.name) + (draft?.clis.keys.map { $0 } ?? [])
        let found = await Task.detached { () -> [String: String] in
            let script = Set(names).sorted().map { "printf '%s\\t%s\\n' \($0) \"$(command -v \($0))\"" }.joined(separator: "; ")
            let out = run("/bin/zsh", ["-lc", script]) ?? ""
            var map: [String: String] = [:]
            for line in out.split(separator: "\n") {
                let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
                if parts.count == 2, !parts[1].isEmpty { map[parts[0]] = parts[1] }
            }
            return map
        }.value
        installed = found
    }

    // MARK: edits

    func addCLI(_ name: String, from t: Template?) {
        guard !name.isEmpty, draft?.clis[name] == nil else { return }
        draft?.clis[name] = RulesDoc.CLI(free: t?.free ?? [], gatedArgs: t?.gatedArgs ?? [])
    }

    func removeCLI(_ name: String) { draft?.clis[name] = nil }

    func binding(_ name: String) -> RulesDoc.CLI? { draft?.clis[name] }

    func update(_ name: String, _ change: (inout RulesDoc.CLI) -> Void) {
        guard var c = draft?.clis[name] else { return }
        change(&c)
        draft?.clis[name] = c
    }

    private func lastLine(_ s: String) -> String {
        s.split(separator: "\n").last.map(String.init)?.replacingOccurrences(of: "approve: ", with: "") ?? "unknown error"
    }
}
