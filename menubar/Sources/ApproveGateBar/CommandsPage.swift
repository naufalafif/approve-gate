import BarCore
import SwiftUI

struct CommandsPage: View {
    @ObservedObject private var store = Store.shared
    @State private var selected: String?
    @State private var adding = false

    var body: some View {
        if let draft = store.draft {
            HSplitView {
                list(draft).frame(minWidth: 200, idealWidth: 220, maxWidth: 280)
                Group {
                    if let name = selected, draft.clis[name] != nil {
                        CommandDetail(name: name, onRemove: { selected = nil })
                    } else {
                        empty
                    }
                }
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            }
            .sheet(isPresented: $adding) {
                AddCommandSheet { name in
                    adding = false
                    if let name { selected = name }
                }
            }
            .onAppear { if selected == nil { selected = draft.clis.keys.sorted().first } }
        } else {
            Page(title: "Commands", subtitle: "") { LoadingCard() }
        }
    }

    private func list(_ draft: RulesDoc) -> some View {
        VStack(spacing: 0) {
            List(selection: $selected) {
                Section("Gated commands") {
                    ForEach(draft.clis.keys.sorted(), id: \.self) { name in
                        let cli = draft.clis[name]
                        HStack(spacing: 9) {
                            Image(systemName: template(for: name)?.symbol ?? "terminal")
                                .frame(width: 18).foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(name).font(.system(size: 13, weight: .medium, design: .monospaced))
                                    .foregroundStyle(cli?.isOff == true ? .secondary : .primary)
                                Text(summary(cli)).font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if cli?.isOff == true {
                                Pill(text: "Off", color: .gray)
                            } else if store.installed[name] == nil {
                                Image(systemName: "questionmark.circle").foregroundStyle(.orange).help("\(name) is not installed on this Mac")
                            }
                        }
                        .tag(name)
                        .padding(.vertical, 2)
                    }
                }
            }
            .listStyle(.sidebar)
            Divider()
            HStack {
                Button { adding = true } label: { Label("Add Command", systemImage: "plus") }
                    .buttonStyle(.borderless)
                Spacer()
            }
            .padding(10)
        }
    }

    private func summary(_ cli: RulesDoc.CLI?) -> String {
        if cli?.isOff == true { return "Gating off · rules kept" }
        let free = cli?.free?.count ?? 0
        let broker = cli?.env?.values.contains { $0.hasPrefix("secret:") } == true ? " · secret" : ""
        return (free == 0 ? "Always asks" : "Asks except \(free) read\(free == 1 ? "" : "s")") + broker
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("Pick a command, or add one").font(.headline)
            Button("Add Command…") { adding = true }.buttonStyle(.borderedProminent)
        }
    }
}

/// One command's rules: when it asks, the read-only list, flags that always ask, and a tester.
struct CommandDetail: View {
    let name: String
    let onRemove: () -> Void
    @ObservedObject private var store = Store.shared
    @ObservedObject private var monitor = Monitor.shared
    @State private var tryText = ""
    @State private var confirmRemove = false

    var body: some View {
        if let cli = store.draft?.clis[name] {
            Page(title: name, subtitle: subtitle) {
                Card {
                    Row(icon: cli.isOff ? "pause.circle.fill" : "hand.raised.fill", tint: cli.isOff ? .gray : .accentColor,
                        title: "Ask before \(name) runs",
                        caption: cli.isOff ? "Off: \(name) runs without asking. The rules below are kept for when you turn it back on."
                                           : "Turn off to pause gating for a while without losing these rules.") {
                        Toggle("", isOn: Binding(get: { store.draft?.clis[name]?.isOff != true },
                                                 set: { on in store.update(name) { $0.disabled = on ? nil : true } }))
                            .labelsHidden().toggleStyle(.switch)
                    }
                }
                Group {
                tester
                Card(title: "When to ask") {
                    Picker("", selection: Binding(get: { (cli.free ?? []).isEmpty ? "always" : "reads" }, set: setMode)) {
                        Text("Every call asks").tag("always")
                        Text("Reads run freely, everything else asks").tag("reads")
                    }
                    .pickerStyle(.radioGroup).labelsHidden()
                    if !(cli.free ?? []).isEmpty {
                        Text("Read-only commands that run without asking. Patterns match the arguments: * means anything.")
                            .font(.caption).foregroundStyle(.secondary)
                        TokenList(items: Binding(get: { store.draft?.clis[name]?.free ?? [] },
                                                 set: { v in store.update(name) { $0.free = v } }),
                                  placeholder: "get *   or   * list*", collapseAfter: 12)
                        if let t = template(for: name), t.free != cli.free {
                            Button("Reset to the suggested list (\(t.free.count))") { store.update(name) { $0.free = t.free } }
                                .buttonStyle(.link).font(.caption)
                        }
                    }
                }
                Card(title: "Flags that always ask") {
                    Text("If any argument matches one of these, the call asks even when it looks like a read. Use it for flags that point the command at another server, account or key.")
                        .font(.caption).foregroundStyle(.secondary)
                    TokenList(items: Binding(get: { store.draft?.clis[name]?.gatedArgs ?? [] },
                                             set: { v in store.update(name) { $0.gatedArgs = v.isEmpty ? nil : v } }),
                              placeholder: "--server*   or   --profile*")
                }
                if let env = cli.env, !env.isEmpty {
                    Card(title: "Credential broker") {
                        ForEach(env.keys.sorted(), id: \.self) { k in
                            Row(icon: env[k]?.hasPrefix("secret:") == true ? "key.fill" : "equal.circle", tint: .green,
                                title: k, caption: env[k]?.hasPrefix("secret:") == true ? "From the Keychain: \(env[k]!.dropFirst(7))" : env[k])
                        }
                        Text("This command runs from \(cli.path ?? "?") with a clean environment. Manage values under Secrets.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                }
                .disabled(cli.isOff)
                .opacity(cli.isOff ? 0.5 : 1)
                HStack {
                    Spacer()
                    Button("Remove \(name) and Its Rules…", role: .destructive) { confirmRemove = true }
                }
            }
            .confirmationDialog("Remove \(name) and its rules?", isPresented: $confirmRemove) {
                Button("Remove", role: .destructive) { store.removeCLI(name); onRemove() }
            } message: {
                Text("\(name) will run without asking, and its read-only list and flags are deleted. To pause it and keep them, turn off \"Ask before \(name) runs\" instead.")
            }
        }
    }

    /// Type a command and see right away whether it would run or ask, and which rule decides.
    private var tester: some View {
        Card {
            HStack(spacing: 8) {
                Text(name).font(.system(size: 13, design: .monospaced)).foregroundStyle(.secondary)
                TextField("try a command, e.g. \(example)", text: $tryText)
                    .textFieldStyle(.plain).font(.system(size: 13, design: .monospaced))
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
            if let draft = store.draft, !tryText.trimmingCharacters(in: .whitespaces).isEmpty {
                let v = verdict(cli: name, args: shellWords(tryText), rules: draft)
                HStack(spacing: 8) {
                    Image(systemName: v.kind == .runs ? "play.circle.fill" : "hand.raised.circle.fill")
                        .font(.system(size: 18)).foregroundStyle(v.kind == .runs ? .green : .orange)
                    Text(v.kind == .runs ? "Runs without asking" : "Asks for your fingerprint").font(.system(size: 13, weight: .semibold))
                    Text(v.reason).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .transition(.opacity)
            } else {
                Text("Type a command to check whether it would run freely or ask.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Where the real command lives, as approve sees it (behind the gate's link).
    private var subtitle: String {
        if store.draft?.clis[name]?.isOff == true { return "Gating is off. \(name) runs as the plain command." }
        if let real = monitor.status?.clis.first(where: { $0.name == name })?.real, !real.isEmpty {
            return "Gated. The real \(name) is \(real)."
        }
        return store.installed[name] == nil ? "Not found on this Mac yet. The rule applies once it is installed."
                                            : "Save to start gating it."
    }

    private var example: String {
        switch name {
        case "kubectl": "delete pod web-1"
        case "terraform": "apply"
        case "aws": "s3 rm s3://bucket/key"
        case "vault": "kv put secret/x a=b"
        default: "list"
        }
    }

    private func setMode(_ mode: String) {
        store.update(name) { cli in
            if mode == "always" { cli.free = [] } else if (cli.free ?? []).isEmpty {
                cli.free = template(for: name)?.free.isEmpty == false ? template(for: name)!.free : ["--help", "* --help", "--version"]
            }
        }
    }
}

/// Pick a command to gate: installed ones first, each with a suggested read-only list, or any name.
struct AddCommandSheet: View {
    let done: (String?) -> Void
    @ObservedObject private var store = Store.shared
    @State private var custom = ""

    private var choices: [Template] {
        templates.filter { store.draft?.clis[$0.name] == nil }
            .sorted { (store.installed[$0.name] != nil ? 0 : 1, $0.name) < (store.installed[$1.name] != nil ? 0 : 1, $1.name) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Make a command ask first").font(.title2.bold())
                Text("Pick one with a suggested list of read-only commands. Reads run freely, anything else waits for your fingerprint. You can change it after.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10)], spacing: 10) {
                    ForEach(choices) { t in
                        Button { add(t.name, t) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: t.symbol).font(.system(size: 18)).frame(width: 26).foregroundStyle(Color.accentColor)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(t.name).font(.system(size: 13, weight: .semibold, design: .monospaced))
                                    Text(t.summary).font(.system(size: 11)).foregroundStyle(.secondary)
                                    Text(store.installed[t.name] != nil ? "Installed" : "Not installed")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(store.installed[t.name] != nil ? .green : .secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
                            .contentShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                        .opacity(store.installed[t.name] != nil ? 1 : 0.7)
                    }
                }
            }
            .frame(height: 300)
            HStack {
                TextField("Any other command, e.g. mysql", text: $custom)
                    .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                    .onSubmit { add(custom, nil) }
                Button("Add") { add(custom, nil) }.disabled(!validName)
                Spacer()
                Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(width: 600)
    }

    private var validName: Bool {
        let n = custom.trimmingCharacters(in: .whitespaces)
        return n.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil && store.draft?.clis[n] == nil
    }

    private func add(_ name: String, _ t: Template?) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard n.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil else { return }
        store.addCLI(n, from: t ?? template(for: n))
        done(n)
    }
}
