// `approve rules ...`: everything the Settings window changes, from the command line, so you (or an
// agent you ask) can change the setup without the window. Every change prints a diff and goes
// through the same gate as the window: in system mode the macOS admin prompt (sudo in a terminal),
// naming the change; in user mode it must be run in a terminal.

import Foundation

let rulesUsage = """
usage: approve rules COMMAND
  show [CLI] [--json]                  the rules, or one command's rules
  templates [--json]                   suggested read-only lists for common CLIs
  add CLI [--empty]                    gate a command (with its suggested list, unless --empty)
  remove CLI                           stop gating it and delete its rules
  disable CLI | enable CLI             pause gating but keep the rules, or turn it back on
  ask CLI always|reads                 every call asks, or read-only calls run freely
  free CLI add|rm PATTERN... | reset   read-only patterns (reset: back to the suggested list)
  gated-arg CLI add|rm PATTERN...      arguments that always ask, e.g. --server*
  timeout SECONDS                      time to answer an approval (10-300)
  ask-on-mac on|off                    Touch ID on the Mac as well as the phone
  production add|rm WORD...            words that mark a target as production
  relay URL|default                    relay `approve pair` uses
  install FILE                         replace the whole rules file
Several changes at once: approve rules show --json > f, edit f, approve rules install f
"""

#if APPROVE_TEST
let defaultLinkDir = "\(configDir)/links"
#else
let defaultLinkDir = "\(home)/.local/bin/touchid-wrap"
#endif

/// Suggested read-only lists, the same as the Settings window's gallery (menubar BarCore templates).
struct Template: Codable {
    var name: String
    var summary: String
    var free: [String]
    var gatedArgs: [String]
}

let templates: [Template] = [
    Template(name: "kubectl", summary: "Kubernetes",
             free: ["get *", "describe *", "logs *", "top *", "explain *", "api-resources*", "config get-contexts*",
                    "config current-context", "version*", "--help", "* --help"],
             gatedArgs: ["--server*", "--kubeconfig*", "--token*"]),
    Template(name: "terraform", summary: "Infrastructure as code",
             free: ["plan*", "show*", "validate*", "fmt -check*", "state list*", "state show*", "output*", "version", "--help", "* --help"],
             gatedArgs: []),
    Template(name: "aws", summary: "Amazon Web Services",
             free: ["* describe-*", "* list-*", "* get-*", "sts get-caller-identity*", "s3 ls*", "--version", "help", "* help"],
             gatedArgs: ["--endpoint-url*", "--profile*"]),
    Template(name: "gcloud", summary: "Google Cloud",
             free: ["* list*", "* describe *", "config list*", "auth list*", "projects list*", "version", "--help", "* --help"],
             gatedArgs: ["--project*", "--account*"]),
    Template(name: "gh", summary: "GitHub CLI",
             free: ["* list*", "* view*", "* status*", "* diff*", "* checks*", "auth status*", "--version", "--help", "* --help"],
             gatedArgs: []),
    Template(name: "glab", summary: "GitLab CLI",
             free: ["* list*", "* view*", "* status*", "* diff*", "auth status*", "--version", "--help", "* --help"],
             gatedArgs: []),
    Template(name: "docker", summary: "Containers",
             free: ["ps*", "images*", "logs *", "inspect *", "version*", "info*", "stats --no-stream*", "--help", "* --help"],
             gatedArgs: ["-H*", "--host*", "--context*"]),
    Template(name: "helm", summary: "Kubernetes packages",
             free: ["list*", "status *", "get *", "history *", "search *", "show *", "version*", "--help", "* --help"],
             gatedArgs: ["--kube-context*", "--kubeconfig*"]),
    Template(name: "vault", summary: "HashiCorp Vault", free: [], gatedArgs: ["-address*", "--address*"]),
    Template(name: "hcloud", summary: "Hetzner Cloud",
             free: ["* list*", "* describe*", "context list", "version", "--help", "* --help"], gatedArgs: []),
    Template(name: "doctl", summary: "DigitalOcean",
             free: ["* list*", "* get*", "account get*", "version", "--help", "* --help"],
             gatedArgs: ["--api-url*", "-u*", "--access-token*", "-t*"]),
    Template(name: "stripe", summary: "Stripe",
             free: ["--version", "version", "config *", "login status*", "--help", "* --help"],
             gatedArgs: ["--api-base*", "--api-key*", "--live"]),
    Template(name: "flyctl", summary: "Fly.io",
             free: ["* list*", "status*", "logs*", "version", "--help", "* --help"], gatedArgs: []),
    Template(name: "wrangler", summary: "Cloudflare Workers",
             free: ["whoami", "* list*", "tail*", "--version", "--help", "* --help"], gatedArgs: []),
    Template(name: "psql", summary: "PostgreSQL shell", free: ["--version", "--help"], gatedArgs: []),
    Template(name: "op", summary: "1Password CLI", free: ["--version", "whoami*", "--help"], gatedArgs: []),
]

/// Links every gated CLI in `dir` to this program, and removes links to an approve binary for
/// commands that were removed or turned off, so they run as the plain command again.
func linkCLIs(_ dir: String, _ rules: Rules) {
    let fm = FileManager.default
    try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let me = ownExecutable()
    let active = Set(rules.clis.filter { $0.value.disabled != true }.keys)
    for entry in ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).sorted() where !active.contains(entry) {
        let link = "\(dir)/\(entry)"
        guard let dest = try? fm.destinationOfSymbolicLink(atPath: link) else { continue }
        let target = realPath(link) ?? dest
        guard (target as NSString).lastPathComponent.hasPrefix("approve") else { continue }
        try? fm.removeItem(atPath: link)
        print("\(link) removed (not gated now)")
    }
    for name in active.sorted() {
        let link = "\(dir)/\(name)"
        try? fm.removeItem(atPath: link)
        do { try fm.createSymbolicLink(atPath: link, withDestinationPath: me) } catch {
            die("could not link \(link): \(error.localizedDescription)")
        }
        print("\(link) -> \(me)")
    }
}

/// Changing the rules: system mode asks for an admin password at the write; user mode has no such
/// prompt, so the change must come from a terminal.
func requireRulesGate(_ what: String) {
    #if APPROVE_TEST
    let needTerminal = ProcessInfo.processInfo.environment["APPROVE_TEST_TTY"] == "1"
    #else
    let needTerminal = !systemMode
    #endif
    if needTerminal, isatty(0) != 1 { die("run `approve rules \(what)` yourself in a terminal", 1) }
}

private typealias JSON = [String: Any]

private func rulesJSON() -> JSON {
    guard let d = readSettings(rulesPath) else { die("no readable rules at \(rulesPath); run approve setup", 1) }
    guard let o = try? JSONSerialization.jsonObject(with: d) as? JSON else { die("\(rulesPath) is not valid JSON", 1) }
    return o
}

private func encode(_ o: Any) -> Data {
    (try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
}

/// Diff of the rules file against `new`; with `old`, against that instead (the current rules in the
/// same layout, so a change shows only what changed, not the reformatting).
private func showDiff(_ new: Data, old: Data? = nil) {
    let tmp = NSTemporaryDirectory() + "approve-rules-" + UUID().uuidString + ".json"
    FileManager.default.createFile(atPath: tmp, contents: new + Data("\n".utf8))
    var from = rulesPath
    if let old {
        from = NSTemporaryDirectory() + "approve-rules-current-" + UUID().uuidString + ".json"
        FileManager.default.createFile(atPath: from, contents: old + Data("\n".utf8))
    }
    defer { try? FileManager.default.removeItem(atPath: tmp); if old != nil { try? FileManager.default.removeItem(atPath: from) } }
    let d = Process()
    d.executableURL = URL(fileURLWithPath: "/usr/bin/diff")
    d.arguments = ["-u", "-L", "rules now", "-L", "after this change", from, tmp]
    try? d.run(); d.waitUntilExit()
}

private func validCLIName(_ n: String) -> Bool {
    n.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil && !n.hasPrefix("approve")
}

private func template(for name: String) -> Template? { templates.first { $0.name == name } }

/// Applies one change to the rules: diff, the gate, the write, then the links if commands changed.
/// What a whole-file rules change does, in words, for the approval prompt (the diff only reaches the
/// caller's output, and the approver must see what they approve). Paths and secrets are named.
func describeRulesChange(old: Data?, new: Data) -> String {
    func obj(_ d: Data?) -> JSON { d.flatMap { try? JSONSerialization.jsonObject(with: $0) as? JSON } ?? [:] }
    func same(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) { case (nil, nil): return true; case let (x?, y?): return (x as AnyObject).isEqual(y); default: return false }
    }
    let o = obj(old), n = obj(new)
    let oc = o["clis"] as? JSON ?? [:], nc = n["clis"] as? JSON ?? [:]
    var parts: [String] = []
    func detail(_ r: JSON) -> String {
        var d: [String] = []
        if let p = r["path"] as? String { d.append("path \(p)") }
        let secrets = (r["env"] as? [String: String] ?? [:]).values.filter { $0.hasPrefix("secret:") }
        if !secrets.isEmpty { d.append("secrets " + secrets.sorted().joined(separator: ",")) }
        if (r["free"] as? [String])?.contains(where: { $0 == "*" }) == true || r["default"] as? String == "free" { d.append("EVERYTHING FREE") }
        return d.isEmpty ? "" : " (" + d.joined(separator: ", ") + ")"
    }
    for k in nc.keys.sorted() where oc[k] == nil { parts.append("gate \(k)" + detail(nc[k] as? JSON ?? [:])) }
    for k in oc.keys.sorted() where nc[k] == nil { parts.append("stop gating \(k)") }
    for k in nc.keys.sorted() {
        guard let a = oc[k] as? JSON, let b = nc[k] as? JSON, !same(a, b) else { continue }
        let fields = Set(a.keys).union(b.keys).filter { !same(a[$0], b[$0]) }.sorted()
        var t = "\(k): " + fields.map { f -> String in
            if f == "free" {
                let add = (b[f] as? [String] ?? []).filter { !(a[f] as? [String] ?? []).contains($0) }
                let rm = (a[f] as? [String] ?? []).filter { !(b[f] as? [String] ?? []).contains($0) }
                return "free" + (add.isEmpty ? "" : " +" + add.joined(separator: " +")) + (rm.isEmpty ? "" : " -" + rm.joined(separator: " -"))
            }
            return f
        }.joined(separator: ", ")
        t += detail(b).isEmpty || (same(a["path"], b["path"]) && same(a["env"], b["env"])) ? "" : detail(b)
        parts.append(t)
    }
    for k in Set(o.keys).union(n.keys).subtracting(["clis", "_comment"]).sorted() where !same(o[k], n[k]) { parts.append("\(k) settings") }
    return visible(parts.joined(separator: "; "))
}

private func change(_ what: String, relink: Bool = false, _ edit: (inout JSON) -> Void) -> Never {
    var o = rulesJSON()
    let before = o as NSDictionary
    edit(&o)
    if before.isEqual(to: o) { print("Nothing to change: \(what)"); exit(0) }
    let data = encode(o) + Data("\n".utf8)
    guard (try? JSONDecoder().decode(Rules.self, from: data)) != nil else { die("that change would make the rules invalid") }
    showDiff(encode(o), old: encode(before))
    do { try writeSettings(data, rulesPath, reason: what) } catch { die("rules not changed: \(error.localizedDescription)", 1) }
    print("Saved: \(what)")
    if relink, let r = loadRules() { linkCLIs(defaultLinkDir, r) }
    exit(0)
}

/// One command's rules, edited in place. Dies if the command is not in the rules.
private func editCLI(_ o: inout JSON, _ name: String, _ edit: (inout JSON) -> Void) {
    var clis = o["clis"] as? JSON ?? [:]
    guard var rule = clis[name] as? JSON else { die("\(name) is not gated; add it with: approve rules add \(name)") }
    edit(&rule)
    clis[name] = rule
    o["clis"] = clis
}

private func requireCLI(_ name: String) {
    guard (rulesJSON()["clis"] as? JSON)?[name] != nil else { die("\(name) is not gated; add it with: approve rules add \(name)") }
}

private func list(_ v: Any?) -> [String] { v as? [String] ?? [] }

private func addAll(_ have: [String], _ new: [String]) -> [String] { have + new.filter { !have.contains($0) } }

private func shown(_ items: [String]) -> String { visible(items.joined(separator: ", ")) }

func runRules(_ argv: [String]) -> Never {
    var a = argv
    let sub = a.isEmpty ? "help" : a.removeFirst()
    let json = a.contains("--json")
    a.removeAll { $0 == "--json" }
    func arg(_ i: Int, _ usage: String) -> String {
        guard i < a.count else { die("usage: approve rules \(usage)") }
        return a[i]
    }
    // Read-only views first: they need no gate.
    switch sub {
    case "show":
        printRules(cli: a.first, json: json)
        exit(0)
    case "templates":
        if json { FileHandle.standardOutput.write(encode(try! JSONSerialization.jsonObject(with: JSONEncoder().encode(templates))) + Data("\n".utf8)) }
        else { for t in templates { print("\(t.name.padding(toLength: 10, withPad: " ", startingAt: 0)) \(t.summary): \(t.free.count) read-only patterns") } }
        exit(0)
    case "help", "--help", "-h":
        print(rulesUsage)
        exit(0)
    default:
        break
    }

    requireRulesGate(sub)
    switch sub {
    case "install":
        let file = arg(0, "install FILE")
        guard let data = FileManager.default.contents(atPath: file),
              (try? JSONDecoder().decode(Rules.self, from: data)) != nil else { die("\(file) is not valid rules JSON") }
        if FileManager.default.fileExists(atPath: rulesPath) { showDiff(data) }
        let summary = describeRulesChange(old: readSettings(rulesPath), new: data)
        if summary.isEmpty { print("Nothing to change: the rules are the same"); exit(0) }
        do { try writeSettings(data, rulesPath, reason: "change its rules: " + summary) } catch { die("rules not changed: \(error.localizedDescription)", 1) }
        print("Rules installed: \(rulesPath)")
        if let r = loadRules() { linkCLIs(defaultLinkDir, r) }
        exit(0)

    case "add":
        let name = arg(0, "add CLI [--empty]")
        guard validCLIName(name) else { die("\(name) is not a command name") }
        let t = a.contains("--empty") ? nil : template(for: name)
        change("start gating \(name)", relink: true) { o in
            var clis = o["clis"] as? JSON ?? [:]
            guard clis[name] == nil else { die("\(name) is already gated; see: approve rules show \(name)") }
            var rule: JSON = ["default": "gated", "free": t?.free ?? []]
            if let g = t?.gatedArgs, !g.isEmpty { rule["gatedArgs"] = g }
            clis[name] = rule
            o["clis"] = clis
        }

    case "remove":
        let name = arg(0, "remove CLI")
        requireCLI(name)
        change("stop gating \(name) and delete its rules", relink: true) { o in
            var clis = o["clis"] as? JSON ?? [:]
            clis[name] = nil
            o["clis"] = clis
        }

    case "disable", "enable":
        let name = arg(0, "\(sub) CLI")
        let off = sub == "disable"
        change(off ? "turn gating off for \(name) (rules kept)" : "turn gating back on for \(name)", relink: true) { o in
            editCLI(&o, name) { $0["disabled"] = off ? true : nil }
        }

    case "ask":
        let name = arg(0, "ask CLI always|reads"), mode = arg(1, "ask CLI always|reads")
        guard ["always", "reads"].contains(mode) else { die("usage: approve rules ask CLI always|reads") }
        change(mode == "always" ? "make every \(name) call ask" : "let read-only \(name) calls run freely") { o in
            editCLI(&o, name) { rule in
                if mode == "always" { rule["free"] = [String]() }
                else if list(rule["free"]).isEmpty {
                    let suggested = template(for: name)?.free ?? []
                    rule["free"] = suggested.isEmpty ? ["--help", "* --help", "--version"] : suggested
                }
            }
        }

    case "free", "gated-arg":
        let usage = sub == "free" ? "free CLI add|rm PATTERN... | free CLI reset" : "gated-arg CLI add|rm PATTERN..."
        let name = arg(0, usage), op = arg(1, usage)
        let patterns = Array(a.dropFirst(2))
        let key = sub == "free" ? "free" : "gatedArgs"
        let noun = sub == "free" ? "read-only patterns" : "arguments that always ask"
        switch op {
        case "add", "rm":
            guard !patterns.isEmpty, patterns.allSatisfy({ !$0.isEmpty }) else { die("usage: approve rules \(usage)") }
            change("\(name): \(op == "add" ? "add" : "remove") \(noun) \(shown(patterns))") { o in
                editCLI(&o, name) { rule in
                    let now = op == "add" ? addAll(list(rule[key]), patterns) : list(rule[key]).filter { !patterns.contains($0) }
                    rule[key] = (key == "gatedArgs" && now.isEmpty) ? nil : now
                }
            }
        case "reset" where sub == "free":
            guard let t = template(for: name) else { die("there is no suggested list for \(name)") }
            change("\(name): reset read-only patterns to the suggested list") { o in editCLI(&o, name) { $0["free"] = t.free } }
        default:
            die("usage: approve rules \(usage)")
        }

    case "timeout":
        guard let s = Int(arg(0, "timeout SECONDS")), (10...300).contains(s) else { die("timeout is 10 to 300 seconds") }
        change("wait \(s) s for an approval") { o in
            var ap = o["approval"] as? JSON ?? [:]
            ap["timeoutSeconds"] = s
            o["approval"] = ap
        }

    case "ask-on-mac":
        let v = arg(0, "ask-on-mac on|off")
        guard v == "on" || v == "off" else { die("usage: approve rules ask-on-mac on|off") }
        change(v == "on" ? "also ask with Touch ID on the Mac" : "stop asking on the Mac while a phone is paired") { o in
            var ap = o["approval"] as? JSON ?? [:]
            ap["askOnMac"] = v == "on"
            o["approval"] = ap
        }

    case "production":
        let op = arg(0, "production add|rm WORD..."), words = Array(a.dropFirst())
        guard ["add", "rm"].contains(op), !words.isEmpty, words.allSatisfy({ !$0.isEmpty }) else { die("usage: approve rules production add|rm WORD...") }
        change("\(op == "add" ? "add" : "remove") production words \(shown(words))") { o in
            let have = list(o["production"])
            o["production"] = op == "add" ? addAll(have, words) : have.filter { !words.contains($0) }
        }

    case "relay":
        let url = arg(0, "relay URL|default")
        if url == "default" {
            change("pair through the default relay (ntfy.sh)") { $0["relay"] = nil }
        }
        let local = url.hasPrefix("http://127.0.0.1") || url.hasPrefix("http://localhost")
        guard url.hasPrefix("https://") || local, URL(string: url)?.host != nil else { die("the relay must be an https:// address") }
        let clean = url.hasSuffix("/") ? String(url.dropLast()) : url
        change("pair through the relay \(visible(clean))") { $0["relay"] = ["server": clean] }

    default:
        die(rulesUsage)
    }
}

private func printRules(cli: String?, json: Bool) {
    let o = rulesJSON()
    let clis = o["clis"] as? JSON ?? [:]
    if let cli {
        guard let rule = clis[cli] as? JSON else { die("\(cli) is not gated") }
        if json { FileHandle.standardOutput.write(encode(rule) + Data("\n".utf8)); return }
        let free = list(rule["free"]), gated = list(rule["gatedArgs"])
        print("\(cli): " + (rule["disabled"] as? Bool == true ? "off (rules kept, runs without asking)" : "gated"))
        print("  when to ask: " + ((rule["default"] as? String) == "free" ? "only for calls a rule names"
                                   : free.isEmpty ? "every call" : "everything except the read-only patterns"))
        if !free.isEmpty { print("  read-only patterns: " + shown(free)) }
        if !gated.isEmpty { print("  arguments that always ask: " + shown(gated)) }
        if let p = rule["path"] as? String { print("  real binary: \(p)") }
        if let env = rule["env"] as? [String: String], !env.isEmpty {
            print("  environment: " + env.keys.sorted().map { k in env[k]!.hasPrefix("secret:") ? "\(k) from the Keychain (\(env[k]!.dropFirst(7)))" : "\(k)=\(env[k]!)" }.joined(separator: ", "))
        }
        return
    }
    if json { FileHandle.standardOutput.write(encode(o) + Data("\n".utf8)); return }
    let ap = o["approval"] as? JSON ?? [:]
    print("Rules: \(rulesPath)")
    print("Approval: wait \(ap["timeoutSeconds"] as? Int ?? 90) s, Touch ID on the Mac \((ap["askOnMac"] as? Bool ?? true) ? "on" : "off")")
    print("Production words: " + shown(list(o["production"])))
    print("Relay for pairing: " + (((o["relay"] as? JSON)?["server"] as? String) ?? "default (https://ntfy.sh)"))
    print("Commands:")
    for name in clis.keys.sorted() {
        let rule = clis[name] as? JSON ?? [:]
        let free = list(rule["free"]).count, gated = list(rule["gatedArgs"]).count
        let state = rule["disabled"] as? Bool == true ? "off (rules kept)"
            : free == 0 ? "every call asks" : "asks except \(free) read-only pattern\(free == 1 ? "" : "s")"
        print("  \(name.padding(toLength: 10, withPad: " ", startingAt: 0)) \(state)\(gated > 0 ? ", \(gated) argument\(gated == 1 ? "" : "s") that always ask" : "")")
    }
}

/// `approve hook install`: adds `approve hook` for Bash and the file tools to Claude Code's settings,
/// keeping everything else. Only adds, so it needs no gate.
func runHookInstall() -> Never {
    #if APPROVE_TEST
    let link = "\(configDir)/claude/settings.json"
    #else
    let link = "\(home)/.claude/settings.json"
    #endif
    let path = (try? FileManager.default.destinationOfSymbolicLink(atPath: link)).map {
        $0.hasPrefix("/") ? $0 : ((link as NSString).deletingLastPathComponent as NSString).appendingPathComponent($0)
    } ?? link
    let existing = FileManager.default.contents(atPath: path)
    var root: [String: Any] = [:]
    if let existing {
        guard let o = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] else { die("\(path) is not valid JSON; not changed", 1) }
        root = o
    }
    var hooks = root["hooks"] as? [String: Any] ?? [:]
    var pre = hooks["PreToolUse"] as? [[String: Any]] ?? []
    var added: [String] = []
    for matcher in ["Bash", "Edit|Write|MultiEdit|NotebookEdit"] {
        let has = pre.contains { ($0["matcher"] as? String) == matcher
            && (($0["hooks"] as? [[String: Any]]) ?? []).contains { ($0["command"] as? String)?.hasSuffix("approve hook") == true } }
        if !has { pre.append(["matcher": matcher, "hooks": [["type": "command", "command": "~/bin/approve hook"]]]); added.append(matcher) }
    }
    if added.isEmpty { print("The hook is already on in \(path)."); exit(0) }
    hooks["PreToolUse"] = pre
    root["hooks"] = hooks
    try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    guard FileManager.default.createFile(atPath: path, contents: encode(root) + Data("\n".utf8)) else { die("could not write \(path)", 1) }
    print("Hook turned on for \(added.joined(separator: " and ")) in \(path). New Claude Code sessions use it.")
    exit(0)
}
