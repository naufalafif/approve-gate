import AppKit
import BarCore
import SwiftUI

enum SettingsPage: String, CaseIterable, Identifiable {
    case overview, commands, approval, phone, secrets, claude, activity
    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .commands: "Commands"
        case .approval: "Approval"
        case .phone: "Phone & Relay"
        case .secrets: "Secrets"
        case .claude: "Claude Code"
        case .activity: "Activity"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "checkmark.shield"
        case .commands: "terminal"
        case .approval: "timer"
        case .phone: "iphone.radiowaves.left.and.right"
        case .secrets: "key"
        case .claude: "sparkles"
        case .activity: "list.bullet.rectangle"
        }
    }
}

struct SettingsView: View {
    @ObservedObject private var store = Store.shared
    @State private var page: SettingsPage? = .overview

    var body: some View {
        NavigationSplitView {
            List(SettingsPage.allCases, selection: $page) { p in
                Label(p.title, systemImage: p.symbol).tag(p)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 205, max: 240)
        } detail: {
            GeometryReader { g in
                VStack(spacing: 0) {
                    Group {
                        switch page ?? .overview {
                        case .overview: OverviewPage(go: { page = $0 })
                        case .commands: CommandsPage()
                        case .approval: ApprovalPage()
                        case .phone: PhonePage()
                        case .secrets: SecretsPage()
                        case .claude: ClaudePage()
                        case .activity: ActivityPage()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    if store.dirty || store.saveMessage != nil { SaveBar() }
                }
                .frame(width: g.size.width, height: g.size.height, alignment: .top)
            }
        }
        .task { await store.load() }
        .onAppear {
            NSApp.setActivationPolicy(.regular) // Dock icon while the window is open
            NSApp.activate(ignoringOtherApps: true)
        }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
    }
}

/// Unsaved changes: what changes and where, with Revert and Save.
struct SaveBar: View {
    @ObservedObject private var store = Store.shared

    var body: some View {
        HStack(spacing: 12) {
            if store.dirty {
                Image(systemName: "pencil.circle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Unsaved changes").font(.system(size: 13, weight: .semibold))
                    Text(store.systemMode ? "Saving asks for Touch ID or your phone, because the rules are owned by root."
                                          : "Saved to your rules file.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } else if let m = store.saveMessage {
                Image(systemName: m == "Saved." ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(m == "Saved." ? .green : .orange)
                Text(m).font(.system(size: 13))
            }
            Spacer()
            if store.dirty {
                Button("Revert") { store.revert() }.disabled(store.saving)
                Button {
                    Task { await store.save() }
                } label: {
                    if store.saving { ProgressView().controlSize(.small) } else { Text("Save") }
                }
                .keyboardShortcut("s")
                .buttonStyle(.borderedProminent)
                .disabled(store.saving)
            } else {
                Button("Dismiss") { store.saveMessage = nil }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

// MARK: - Overview

struct OverviewPage: View {
    @ObservedObject private var monitor = Monitor.shared
    let go: (SettingsPage) -> Void

    var body: some View {
        Page(title: "Overview", subtitle: "Risky commands wait for your fingerprint on this Mac or your phone. Here is how it stands.") {
            Card {
                HStack(spacing: 14) {
                    Image(systemName: icon).font(.system(size: 34, weight: .semibold)).foregroundStyle(color)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(headline).font(.title3.bold())
                        Text(monitor.checkedAt.map { "Checked \($0.formatted(date: .omitted, time: .shortened))" } ?? "Checking…")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Check Now") { Task { await monitor.refresh() } }
                }
            }
            if let r = monitor.report {
                Card(title: "Status") {
                    ForEach(Array(r.findings.enumerated()), id: \.offset) { _, f in
                        Row(icon: f.problem ? "exclamationmark.triangle.fill" : "checkmark",
                            tint: f.problem ? .orange : .green, title: f.text)
                    }
                }
            } else if let e = monitor.error {
                Card { Row(icon: "xmark", tint: .red, title: e, caption: "Install with Homebrew, then run approve setup.") }
            }
            Card(title: "Shortcuts") {
                Row(icon: "terminal", title: "Make a command ask first", caption: "Add kubectl, terraform, aws and more in a few clicks.") {
                    Button("Commands") { go(.commands) }
                }
                Row(icon: "iphone", tint: .purple, title: "Pair a phone", caption: "Approve from your phone when you are away from the Mac.") {
                    Button("Phone & Relay") { go(.phone) }
                }
            }
        }
    }

    private var icon: String {
        guard let r = monitor.report else { return monitor.error == nil ? "shield" : "xmark.shield.fill" }
        return r.problems == 0 ? "checkmark.shield.fill" : "exclamationmark.shield.fill"
    }

    private var color: Color {
        guard let r = monitor.report else { return monitor.error == nil ? .secondary : .red }
        return r.problems == 0 ? .green : .orange
    }

    private var headline: String {
        guard let r = monitor.report else { return monitor.error == nil ? "Checking…" : "Not working" }
        return r.problems == 0 ? "Ready" : "\(r.problems) thing\(r.problems == 1 ? "" : "s") need\(r.problems == 1 ? "s" : "") attention"
    }
}

// MARK: - Approval

struct ApprovalPage: View {
    @ObservedObject private var store = Store.shared

    var body: some View {
        Page(title: "Approval", subtitle: "How long a request waits, where it asks, and what counts as production.") {
            if store.draft != nil {
                Card(title: "Waiting for an answer") {
                    Row(icon: "timer", tint: .blue, title: "Time to answer",
                        caption: "After this, the command is refused. Short is safer; long gives you time to reach your phone.") {
                        Text("\(timeout) s").font(.system(size: 13, weight: .semibold).monospacedDigit()).frame(width: 52, alignment: .trailing)
                    }
                    Slider(value: Binding(get: { Double(timeout) }, set: { setTimeout(Int(($0 / 5).rounded()) * 5) }), in: 15...300) {
                        EmptyView()
                    } minimumValueLabel: { Text("15 s").font(.caption) } maximumValueLabel: { Text("5 min").font(.caption) }
                    .padding(.leading, 38)
                }
                Card(title: "Where to ask") {
                    Row(icon: "touchid", tint: .pink, title: "Touch ID on this Mac",
                        caption: "Off: only the phone asks while one is paired. Without a phone the Mac always asks.") {
                        Toggle("", isOn: Binding(get: { store.draft?.askOnMac ?? true }, set: { v in
                            store.draft?.approval = .init(timeoutSeconds: store.draft?.approval?.timeoutSeconds, askOnMac: v)
                        })).labelsHidden().toggleStyle(.switch)
                    }
                    Row(icon: "iphone", tint: .purple, title: "Your phone", caption: "Set up under Phone & Relay.")
                }
                Card(title: "Production") {
                    Row(icon: "exclamationmark.octagon", tint: .red, title: "Words that mean production",
                        caption: "A target containing one of these (a Vault address, a context name) is shown in red on both devices.")
                    TokenList(items: Binding(get: { store.draft?.production ?? [] }, set: { store.draft?.production = $0 }),
                              placeholder: "prod, live, vault.example.com", monospaced: false)
                        .padding(.leading, 38)
                }
            } else {
                LoadingCard()
            }
        }
    }

    private var timeout: Int { store.draft?.timeout ?? 90 }

    private func setTimeout(_ v: Int) {
        store.draft?.approval = .init(timeoutSeconds: v, askOnMac: store.draft?.approval?.askOnMac)
    }
}

struct LoadingCard: View {
    @ObservedObject private var store = Store.shared
    var body: some View {
        Card {
            if let e = store.loadError { Row(icon: "xmark", tint: .red, title: e) } else { ProgressView() }
        }
    }
}

// MARK: - Phone & Relay

struct PhonePage: View {
    @ObservedObject private var store = Store.shared
    @ObservedObject private var monitor = Monitor.shared
    @State private var pairing = false
    @State private var customRelay = ""
    @State private var unpairMessage: String?
    @State private var unpairing = false

    private static let ntfy = "https://ntfy.sh"

    var body: some View {
        Page(title: "Phone & Relay", subtitle: "Your phone gets each request through a relay. The relay only ever sees encrypted messages.") {
            Card(title: "Phone") {
                if let s = monitor.status, s.paired {
                    Row(icon: "iphone", tint: .purple, title: s.phone ?? "Paired phone",
                        caption: "Requests arrive as notifications; approve with your fingerprint.") {
                        Pill(text: s.relayOK == true ? "Connected" : "Relay unreachable", color: s.relayOK == true ? .green : .orange)
                    }
                    HStack {
                        Button("Pair a different phone…") { pairing = true }
                        Button("Unpair", role: .destructive) { Task { await unpair() } }.disabled(unpairing)
                        if unpairing { ProgressView().controlSize(.small) }
                    }
                    .padding(.leading, 38)
                } else {
                    Row(icon: "iphone.slash", tint: .gray, title: "No phone paired", caption: "Only Touch ID on this Mac can approve.") {
                        Button("Pair a phone…") { pairing = true }.buttonStyle(.borderedProminent)
                    }
                }
                if let m = unpairMessage { Text(m).font(.callout).foregroundStyle(.secondary).padding(.leading, 38) }
            }
            Card(title: "Relay for new pairings") {
                if store.draft != nil {
                    Picker("", selection: Binding(get: { relayChoice }, set: setRelayChoice)) {
                        Text("ntfy.sh (free, public)").tag("ntfy")
                        Text("My own relay").tag("own")
                    }
                    .pickerStyle(.radioGroup).labelsHidden()
                    if relayChoice == "own" {
                        HStack {
                            TextField("https://approve-gate-relay.you.workers.dev", text: $customRelay)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { store.draft?.relay = .init(server: customRelay.trimmingCharacters(in: .whitespaces)) }
                            Button("Use") { store.draft?.relay = .init(server: customRelay.trimmingCharacters(in: .whitespaces)) }
                                .disabled(!customRelay.hasPrefix("https://"))
                        }
                        Text("Deploy your own with the relay folder in the repo (a Cloudflare Worker). Must start with https://.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let s = monitor.status, s.paired, let current = s.relay {
                        Text("The phone is paired through \(current). A new relay applies the next time you pair.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    LoadingCard()
                }
            }
        }
        .onAppear { customRelay = store.draft?.relay?.server ?? pairedServer ?? "" }
        .sheet(isPresented: $pairing) {
            PairSheet(server: store.saved?.relay?.server ?? pairedServer ?? Self.ntfy) { pairing = false }
        }
    }

    /// The relay the phone is paired through now, as a URL.
    private var pairedServer: String? { monitor.status?.relay.map { $0.contains("://") ? $0 : "https://\($0)" } }

    /// With no relay set in the rules, the next pairing keeps the relay in use now.
    private var relayChoice: String {
        let s = store.draft?.relay?.server ?? pairedServer ?? Self.ntfy
        return s == Self.ntfy ? "ntfy" : "own"
    }

    private func setRelayChoice(_ v: String) {
        if v == "ntfy" { store.draft?.relay = nil } else if !customRelay.isEmpty { store.draft?.relay = .init(server: customRelay) }
        else { store.draft?.relay = .init(server: "https://") }
    }

    private func unpair() async {
        unpairing = true
        unpairMessage = "Approve on your Mac or phone to unpair…"
        let (code, out) = await approve(["unpair"])
        unpairing = false
        unpairMessage = code == 0 ? "Unpaired. Only Touch ID on this Mac can approve now." : "Not unpaired: \(out.split(separator: "\n").last ?? "")"
        await monitor.refresh()
    }
}

/// Runs `approve pair` and walks through it: approve the change, scan the code, done.
struct PairSheet: View {
    let server: String
    let close: () -> Void
    @StateObject private var session = PairSession()

    var body: some View {
        VStack(spacing: 18) {
            Text("Pair a phone").font(.title2.bold())
            switch session.state {
            case .starting:
                ProgressView("Starting…").frame(height: 300)
            case .approving(let phone):
                VStack(spacing: 12) {
                    Image(systemName: "touchid").font(.system(size: 54)).foregroundStyle(.pink)
                    Text("Approve this change").font(.headline)
                    Text("\(phone) is paired now. Confirm with Touch ID on this Mac or on that phone before a new phone can take its place.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                }.frame(height: 300)
            case .scan(let link):
                QRCode(text: link).frame(width: 240, height: 240)
                    .padding(10).background(.white, in: RoundedRectangle(cornerRadius: 12))
                VStack(spacing: 4) {
                    Text("Scan with the Approve Gate app").font(.headline)
                    Text("Open the app, tap Scan pairing code, then confirm with your fingerprint. The phone then shows a code; this Mac shows the same code before you approve.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Text("Relay: \(URL(string: server)?.host ?? server)").font(.caption).foregroundStyle(.tertiary)
                }
            case .confirm(let phone, let code):
                VStack(spacing: 12) {
                    Image(systemName: "touchid").font(.system(size: 54)).foregroundStyle(.pink)
                    Text("Check the code").font(.headline)
                    Text(code).font(.system(size: 34, weight: .semibold, design: .monospaced))
                    Text("\(phone) answered. Approve with Touch ID only if your phone shows this same code. If it shows a different code, deny: another program tried to pair.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                }.frame(height: 300)
            case .done(let phone):
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 60)).foregroundStyle(.green)
                    Text("Paired with \(phone)").font(.headline)
                    Text("Risky commands now ask on this Mac and on the phone.").foregroundStyle(.secondary)
                }.frame(height: 300)
            case .failed(let why):
                VStack(spacing: 12) {
                    Image(systemName: "xmark.octagon.fill").font(.system(size: 54)).foregroundStyle(.red)
                    Text("Not paired").font(.headline)
                    Text(why).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Text("Nothing changed: the previous pairing still works.").font(.caption).foregroundStyle(.secondary)
                }.frame(height: 300)
            }
            HStack {
                Spacer()
                if case .done = session.state {
                    Button("Done") { close() }.keyboardShortcut(.defaultAction)
                } else if case .failed = session.state {
                    Button("Try Again") { session.start(server: server) }
                    Button("Close") { close() }.keyboardShortcut(.cancelAction)
                } else {
                    Button("Cancel") { session.cancel(); close() }.keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(24)
        .frame(width: 420)
        .onAppear { session.start(server: server) }
        .onDisappear { session.cancel() }
    }
}

@MainActor
final class PairSession: ObservableObject {
    enum State: Equatable { case starting, approving(String), scan(String), confirm(String, String), done(String), failed(String) }
    @Published var state: State = .starting
    private var process: Process?
    private var buffer = ""
    private var link = ""

    func start(server: String) {
        cancel()
        state = .starting
        buffer = ""
        guard let bin = approveBinary() else { state = .failed("approve is not installed."); return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["pair", "--link", "--server", server]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.consume(text) }
        }
        p.terminationHandler = { [weak self] proc in
            Task { @MainActor in self?.finished(proc.terminationStatus) }
        }
        do { try p.run(); process = p } catch { state = .failed("Could not start approve: \(error.localizedDescription)") }
    }

    func cancel() {
        process?.terminationHandler = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil
    }

    private func consume(_ text: String) {
        buffer += text
        for line in buffer.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("Changing the pairing with "), case .starting = state {
                let phone = line.dropFirst("Changing the pairing with ".count).components(separatedBy: " needs").first ?? "A phone"
                state = .approving(phone)
            } else if line.hasPrefix("PAIRLINK ") {
                link = String(line.dropFirst("PAIRLINK ".count))
                state = .scan(link)
            } else if line.hasPrefix("A phone answered with pairing code ") {
                // The code is fixed-width and comes first; the name after it is chosen by the phone.
                let rest = line.dropFirst("A phone answered with pairing code ".count)
                let code = String(rest.prefix(7))
                let phone = rest.range(of: "(it says it is ").map { String(rest[$0.upperBound...].dropLast(2)) } ?? "A phone"
                state = .confirm(phone, code)
            } else if line.hasPrefix("Not paired with that phone"), !link.isEmpty {
                state = .scan(link)
            } else if line.hasPrefix("Paired with ") {
                let phone = line.dropFirst("Paired with ".count).components(separatedBy: ".").first ?? "your phone"
                state = .done(phone)
            }
        }
    }

    private func finished(_ code: Int32) {
        process = nil
        if case .done = state { Task { await Monitor.shared.refresh() }; return }
        let last = buffer.split(separator: "\n").last { $0.hasPrefix("approve:") }
        let why = last.map { String($0.dropFirst("approve: ".count)) } ?? "approve stopped (exit \(code))."
        state = .failed(why.prefix(1).uppercased() + why.dropFirst())
    }
}

// MARK: - Secrets

struct SecretsPage: View {
    @ObservedObject private var monitor = Monitor.shared
    @State private var stored: [String] = []
    @State private var editing: String?
    @State private var value = ""
    @State private var newName = ""
    @State private var message: String?

    var body: some View {
        Page(title: "Secrets", subtitle: "Credentials kept in the Keychain, readable only by approve. A command gets its secret only after the rules or your approval allow the call.") {
            Card(title: "Used by your rules") {
                let wanted = (monitor.status?.clis ?? []).flatMap { c in c.secrets.map { (c.name, $0) } }
                if wanted.isEmpty {
                    Row(icon: "key", tint: .gray, title: "No command uses a secret yet",
                        caption: "Give a command an env entry such as VAULT_TOKEN: secret:vault-token in its rules to start.")
                }
                ForEach(wanted, id: \.1) { cli, name in
                    Row(icon: "key.fill", tint: stored.contains(name) ? .green : .orange, title: name, caption: "Used by \(cli)") {
                        HStack {
                            Pill(text: stored.contains(name) ? "Set" : "Missing", color: stored.contains(name) ? .green : .orange)
                            Button(stored.contains(name) ? "Replace…" : "Set…") { editing = name; value = "" }
                        }
                    }
                }
            }
            Card(title: "All stored secrets") {
                if stored.isEmpty { Text("None yet.").foregroundStyle(.secondary) }
                ForEach(stored, id: \.self) { name in
                    Row(icon: "key", title: name) {
                        Button("Remove", role: .destructive) { Task { await remove(name) } }
                    }
                }
                HStack {
                    TextField("new-secret-name", text: $newName).textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                    Button("Add…") { editing = newName; value = "" }.disabled(newName.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) == nil)
                }
                if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
            }
        }
        .task { await reload() }
        .sheet(item: Binding(get: { editing.map(Ident.init) }, set: { editing = $0?.id })) { item in
            VStack(alignment: .leading, spacing: 14) {
                Text("Set \(item.id)").font(.title3.bold())
                Text("Stored in your Keychain, readable only by approve. Approve the change on your Mac or phone when asked.")
                    .font(.callout).foregroundStyle(.secondary)
                SecureField("Value", text: $value).textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("Cancel") { editing = nil }.keyboardShortcut(.cancelAction)
                    Button("Save") { let n = item.id; editing = nil; Task { await set(n) } }
                        .keyboardShortcut(.defaultAction).disabled(value.isEmpty)
                }
            }
            .padding(22).frame(width: 400)
        }
    }

    private func reload() async {
        let (code, out) = await approve(["secret", "list"])
        stored = code == 0 && !out.hasPrefix("No secrets") ? out.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("approve:") } : []
    }

    private func set(_ name: String) async {
        message = "Approve on your Mac or phone to store \(name)…"
        let (code, out) = await approve(["secret", "set", name], input: value)
        value = ""
        message = code == 0 ? "Stored \(name)." : "Not stored: \(out.split(separator: "\n").last ?? "")"
        await reload()
        await Monitor.shared.refresh()
    }

    private func remove(_ name: String) async {
        message = "Approve on your Mac or phone to remove \(name)…"
        let (code, out) = await approve(["secret", "rm", name])
        message = code == 0 ? "Removed \(name)." : "Not removed: \(out.split(separator: "\n").last ?? "")"
        await reload()
    }
}

struct Ident: Identifiable { let id: String }

// MARK: - Claude Code

struct ClaudePage: View {
    @ObservedObject private var monitor = Monitor.shared
    @State private var message: String?

    var body: some View {
        Page(title: "Claude Code", subtitle: "A check that runs before every command Claude Code starts, and before it edits files.") {
            Card(title: "The approve hook") {
                let hook = monitor.status?.hook ?? [:]
                Row(icon: "terminal", tint: .indigo, title: "Shell commands",
                    caption: "Blocks direct calls to real binaries, destructive production commands and changes to Approve Gate's own files.") {
                    Pill(text: hook["bash"] == true ? "On" : "Off", color: hook["bash"] == true ? .green : .orange)
                }
                Row(icon: "doc.text", tint: .indigo, title: "File edits",
                    caption: "Blocks edits to Approve Gate's files and edits that turn the hook off.") {
                    Pill(text: hook["fileTools"] == true ? "On" : "Off", color: hook["fileTools"] == true ? .green : .orange)
                }
                if hook["bash"] != true || hook["fileTools"] != true {
                    HStack {
                        Button("Turn On") { Task { message = await HookInstaller.install(); await monitor.refresh() } }.buttonStyle(.borderedProminent)
                        Text("Adds the hook to ~/.claude/settings.json.").font(.caption).foregroundStyle(.secondary)
                    }.padding(.leading, 38)
                }
                if let message { Text(message).font(.callout).foregroundStyle(.secondary).padding(.leading, 38) }
            }
            Card(title: "Good to know") {
                Row(icon: "info.circle", tint: .gray, title: "A seatbelt, not a wall",
                    caption: "The hook matches command text. System mode and the credential broker are what actually stop a program from skipping the gate.")
            }
        }
    }
}

/// Turns the hook on through `approve hook install`, which adds it for Bash and the file tools and
/// keeps everything else in ~/.claude/settings.json.
enum HookInstaller {
    static func install() async -> String {
        let (code, out) = await approve(["hook", "install"])
        let last = out.split(separator: "\n").last.map(String.init) ?? ""
        return code == 0 ? "Turned on. New Claude Code sessions use it." : "Not turned on: \(last.replacingOccurrences(of: "approve: ", with: ""))"
    }
}

// MARK: - Activity

struct ActivityPage: View {
    @State private var entries: [LogEntry] = []
    @State private var filter = "all"
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Activity").font(.title2.bold())
                Text("Every call through Approve Gate, newest first.").font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Picker("", selection: $filter) {
                    Text("All").tag("all"); Text("Asked").tag("asked"); Text("Approved").tag("approved")
                    Text("Denied").tag("denied"); Text("No answer").tag("timeout"); Text("Ran freely").tag("free")
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 520)
                Spacer()
                TextField("Search commands", text: $search).textFieldStyle(.roundedBorder).frame(width: 200)
                Button { load() } label: { Image(systemName: "arrow.clockwise") }.help("Reload")
            }
            Table(filtered) {
                TableColumn("When") { e in
                    Text(e.date.map { $0.formatted(.dateTime.day().month(.abbreviated).hour().minute()) } ?? "").monospacedDigit()
                }.width(min: 110, ideal: 130, max: 150)
                TableColumn("Result") { e in Pill(text: label(e), color: color(e)) }.width(min: 110, ideal: 125, max: 140)
                TableColumn("Command") { e in Text(e.command).font(.system(size: 12, design: .monospaced)).lineLimit(1).help(e.command) }
                TableColumn("From") { e in Text(e.caller == "claude" ? "Claude" : "Terminal").foregroundStyle(.secondary) }.width(min: 60, ideal: 70, max: 80)
            }
        }
        .padding(24)
        .onAppear(perform: load)
    }

    private var filtered: [LogEntry] {
        entries.filter { e in
            let f = switch filter {
            case "all": true
            case "asked": e.decision != "free"
            default: e.decision == filter
            }
            return f && (search.isEmpty || e.command.localizedCaseInsensitiveContains(search))
        }
    }

    private func load() {
        let text = (try? String(contentsOfFile: NSHomeDirectory() + "/.approve-gate.log", encoding: .utf8)) ?? ""
        entries = parseLog(text, limit: 1000)
    }

    private func label(_ e: LogEntry) -> String {
        switch e.decision {
        case "approved": e.via == "phone" ? "Approved · phone" : "Approved · Mac"
        case "denied": "Denied"
        case "timeout": "No answer"
        case "free": "Ran freely"
        default: e.decision.capitalized
        }
    }

    private func color(_ e: LogEntry) -> Color {
        switch e.decision {
        case "approved": .green
        case "denied": .red
        case "timeout": .orange
        default: .secondary
        }
    }
}
