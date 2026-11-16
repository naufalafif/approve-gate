import AppKit
import BarCore
import ServiceManagement
import SwiftUI

/// The approve to ask, as a terminal would find it. A Homebrew or ~/bin copy hands over to the
/// root-owned binary and says whether that one is out of date.
/// The root-owned copy first: the app passes it secret values, and a Homebrew or ~/bin copy is a file
/// any program running as you could replace. The others are for user mode only.
let approveCandidates = ["/usr/local/libexec/approve-gate/approve", "/opt/homebrew/bin/approve", "/usr/local/bin/approve",
                         NSHomeDirectory() + "/bin/approve"]
let linkDir = NSHomeDirectory() + "/.local/bin/touchid-wrap"
let logPath = NSHomeDirectory() + "/.approve-gate.log"

/// Status plus each CLI as a login shell resolves it, or why it could not be read.
func readStatus(_ override: String? = nil) -> (GateStatus?, [String: String], String?) {
    guard let bin = override ?? approveCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
        return (nil, [:], "approve is not installed")
    }
    guard let json = run(bin, ["status", "--json"]), let data = json.data(using: .utf8),
          let s = try? JSONDecoder().decode(GateStatus.self, from: data) else {
        return (nil, [:], "approve status failed (\(bin) may be an older build: update it)")
    }
    // What a terminal would run for each CLI: ask a login shell, which loads your PATH setup.
    let names = s.clis.map(\.name)
    let script = names.map { "command -v \($0) || echo" }.joined(separator: "; ")
    let lines = (run("/bin/zsh", ["-lc", script]) ?? "").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var resolved: [String: String] = [:]
    for (i, n) in names.enumerated() { resolved[n] = i < lines.count ? lines[i] : "" }
    return (s, resolved, nil)
}

@MainActor
final class Monitor: ObservableObject {
    static let shared = Monitor()
    @Published var status: GateStatus?
    @Published var report: Report?
    @Published var error: String?
    @Published var checkedAt: Date?
    private var loop: Task<Void, Never>?

    init() {
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }

    func refresh() async {
        let result = await Task.detached(priority: .utility) { readStatus() }.value
        status = result.0
        error = result.2
        report = result.0.map { Report($0, resolved: result.1, linkDir: linkDir) }
        checkedAt = Date()
    }
}

/// `ApproveGateBar --print`: the menu as text, for checking without opening the menu.
func printMenu(_ approve: String?) {
    let (s, resolved, err) = readStatus(approve)
    if let err { print("Approve Gate: \(err)"); return }
    guard let s else { return }
    let r = Report(s, resolved: resolved, linkDir: linkDir)
    print(r.problems == 0 ? "Approve Gate: ready" : "Approve Gate: \(r.problems) need attention")
    for f in r.findings { print("\(f.problem ? "⚠" : "✓") \(f.text)") }
    print("Recent:")
    for d in s.recent { print("  \(describe(d))") }
}

@main
struct Main {
    static func main() {
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            MainActor.assumeIsolated { Snapshot.run(CommandLine.arguments[i + 1], dark: CommandLine.arguments.contains("--dark")) }
            return
        }
        if CommandLine.arguments.contains("--print") {
            let args = CommandLine.arguments
            printMenu(args.firstIndex(of: "--approve").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil })
            return
        }
        ApproveGateBar.main()
    }
}

struct ApproveGateBar: App {
    @ObservedObject private var monitor = Monitor.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent(monitor: monitor)
        } label: {
            Image(systemName: iconName)
        }
        Window("Approve Gate", id: "settings") {
            SettingsView()
        }
        .defaultSize(width: 920, height: 640)
        .windowResizability(.contentMinSize)
        // A menu bar app opens no window at launch, unless started with --settings.
        .defaultLaunchBehavior(CommandLine.arguments.contains("--settings") ? .presented : .suppressed)
    }

    private var iconName: String {
        if monitor.error != nil { return "xmark.shield" }
        guard let r = monitor.report else { return "shield" }
        return r.problems == 0 ? "checkmark.shield" : "exclamationmark.shield"
    }
}

struct MenuContent: View {
    @ObservedObject var monitor: Monitor
    @Environment(\.openWindow) private var openWindow
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        if let e = monitor.error {
            Label("Approve Gate: \(e)", systemImage: "xmark.octagon")
        } else if let r = monitor.report {
            Text(r.problems == 0 ? "Approve Gate: ready" : "Approve Gate: \(r.problems) need\(r.problems == 1 ? "s" : "") attention")
            Divider()
            ForEach(Array(r.findings.enumerated()), id: \.offset) { _, f in
                Label(f.text, systemImage: f.problem ? "exclamationmark.triangle" : "checkmark.circle")
            }
        } else {
            Text("Approve Gate: checking…")
        }
        if let recent = monitor.status?.recent, !recent.isEmpty {
            Divider()
            Menu("Recent") {
                ForEach(Array(recent.enumerated()), id: \.offset) { _, d in Text(describe(d)) }
            }
        }
        Divider()
        if let at = monitor.checkedAt {
            Text("Checked \(at.formatted(date: .omitted, time: .shortened))")
        }
        Button("Settings…") { openSettings() }
            .keyboardShortcut(",")
        Button("Check Now") { Task { await monitor.refresh() } }
            .keyboardShortcut("r")
        Toggle("Launch at Login", isOn: $launchAtLogin)
            .onChange(of: launchAtLogin) {
                if launchAtLogin { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
            }
        Divider()
        Button("Quit Approve Gate") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func openSettings() {
        NSApp.setActivationPolicy(.regular)
        openWindow(id: "settings")
        NSApp.activate(ignoringOtherApps: true)
    }
}
