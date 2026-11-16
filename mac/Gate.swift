// Wrapper mode: `approve` linked as vault, hcloud, doctl, kcadm, rd or stripe. Read-only calls
// listed as free in rules.json run straight away; everything else needs an approval first.
//
// With "env" in a CLI's rules, approve is also that CLI's credential broker: secrets come from
// the Keychain (readable only by approve) and reach the real CLI only after the rules or an
// approval allow the call, in a clean environment, from a fixed path.

import Foundation

struct CLIRule: Codable {
    var `default`: String?
    var free: [String]?
    /// Absolute path of the real CLI. Required when the CLI gets secrets.
    var path: String?
    /// Environment for the real CLI: "secret:NAME" (from the Keychain) or a literal value.
    var env: [String: String]?
    /// Any single argument matching one of these globs makes the call ask, even if it would be free
    /// (for example flags that point the CLI at another server).
    var gatedArgs: [String]?
    /// "isolated" (default when the CLI gets secrets) or "user": which HOME the real CLI sees.
    var home: String?
    /// Gating paused: the command runs as if it were not gated, and the rules are kept for later.
    var disabled: Bool?

    var hasSecrets: Bool { env?.values.contains { $0.hasPrefix("secret:") } ?? false }
}

struct GuardRules: Codable {
    var hcloudProductionContexts: [String]
}

struct ApprovalSettings: Codable {
    /// Seconds to wait for an answer (10-300, default 90).
    var timeoutSeconds: Int?
    /// Also show the Touch ID prompt on the Mac (default true). Off: phone only, while one is paired.
    var askOnMac: Bool?
}

struct RelaySettings: Codable {
    /// Relay used by `approve pair` when --server is not given (default https://ntfy.sh).
    var server: String?
}

struct Rules: Codable {
    var clis: [String: CLIRule]
    var guardRules: GuardRules?
    var production: [String]?
    var approval: ApprovalSettings?
    var relay: RelaySettings?

    enum CodingKeys: String, CodingKey {
        case clis, production, approval, relay
        case guardRules = "guard"
    }
}

var rulesPath: String { "\(settingsDir)/rules.json" }

func loadRules(_ path: String? = nil) -> Rules? {
    // A path given for tests or `check` is read as is; the live rules must pass the system checks.
    guard let d = path.map({ FileManager.default.contents(atPath: $0) }) ?? readSettings(rulesPath) else { return nil }
    return try? JSONDecoder().decode(Rules.self, from: d)
}

/// A read-only pattern matches word by word from the start: each word is a shell glob for the
/// argument in the same place, and only a last word ending in "*" lets more arguments follow.
/// So "* list*" matches `server list -o json` but not `server create --name list`, and "* --help"
/// matches `server --help` but not `exec pod -- sh --help`. An empty pattern matches no arguments.
func freeMatch(_ pattern: String, _ args: [String]) -> Bool {
    let words = pattern.split(separator: " ").map(String.init)
    guard let last = words.last else { return args.isEmpty }
    guard args.count >= words.count else { return false }
    for (w, a) in zip(words, args) where fnmatch(w, a, 0) != 0 { return false }
    return args.count == words.count || last.hasSuffix("*")
}

/// "free" or "gated". Free patterns match word by word (freeMatch). No rules,
/// or a CLI without rules, means gated. A gated argument makes the whole call gated.
func gateDecision(cli: String, args: [String], rules: Rules?) -> String {
    guard let rule = rules?.clis[cli] else { return "gated" }
    for arg in args {
        for pattern in rule.gatedArgs ?? [] where fnmatch(pattern, arg, 0) == 0 { return "gated" }
    }
    for pattern in rule.free ?? [] where freeMatch(pattern, args) {
        return "free"
    }
    return rule.default == "free" ? "free" : "gated"
}

func realPath(_ p: String) -> String? {
    guard let r = realpath(p, nil) else { return nil }
    defer { free(r) }
    return String(cString: r)
}

func ownExecutable() -> String {
    var size: UInt32 = 0
    _NSGetExecutablePath(nil, &size)
    var buf = [CChar](repeating: 0, count: Int(size))
    _NSGetExecutablePath(&buf, &size)
    let p = String(cString: buf)
    return realPath(p) ?? p
}

/// First `name` on PATH that is not this program or another approve binary (another install's link).
func findReal(_ name: String) -> String? {
    let me = ownExecutable()
    let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
    // Absolute PATH entries only: a relative one would run whatever sits in the current folder.
    for dir in path.split(separator: ":") where dir.hasPrefix("/") {
        let cand = "\(dir)/\(name)"
        guard FileManager.default.isExecutableFile(atPath: cand), let r = realPath(cand), r != me,
              !(r as NSString).lastPathComponent.hasPrefix("approve") else { continue }
        return cand
    }
    return nil
}

/// The real CLI: the fixed path from the rules if set, else the next one on PATH. A CLI that gets
/// secrets must have a fixed path, so changing PATH cannot hand the secrets to another program.
func resolveReal(_ name: String, _ rule: CLIRule?) -> String {
    if let p = rule?.path {
        guard p.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: p), realPath(p) != ownExecutable() else {
            die("\(name): the path in the rules (\(p)) is not an executable real CLI", 127)
        }
        // A CLI that gets secrets must be a file nothing running as you can replace: otherwise a
        // program could swap in its own script and receive the secret on the next free call.
        if systemMode, rule?.hasSecrets == true, !rootOwnedChain(p) {
            die("\(name) gets secrets, so its path (\(p)) and every folder above it must be root-owned and not writable by others", 127)
        }
        return p
    }
    if rule?.hasSecrets == true { die("\(name) gets secrets, so its rules need a fixed \"path\"", 127) }
    guard let real = findReal(name) else { die("real '\(name)' not found on PATH", 127) }
    return real
}

/// True when the file (after resolving links) and every folder up to / are owned by root (the test
/// build: also by you) and writable by nobody else.
func rootOwnedChain(_ path: String) -> Bool {
    guard var p = realPath(path) else { return false }
    while true {
        var st = stat()
        guard lstat(p, &st) == 0, st.st_uid == 0 || st.st_uid == systemOwner, st.st_mode & 0o022 == 0 else { return false }
        if p == "/" { return true }
        p = (p as NSString).deletingLastPathComponent
    }
}

/// nil: the real CLI inherits this environment. Otherwise a clean one: the basics, a fixed PATH, an
/// isolated HOME (so files in your home cannot point the CLI at another server), then the rules' values.
func brokerEnvironment(_ name: String, _ rule: CLIRule?) -> [String: String]? {
    guard let rule, let wanted = rule.env, !wanted.isEmpty else { return nil }
    let current = ProcessInfo.processInfo.environment
    var env: [String: String] = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
    for k in ["USER", "LOGNAME", "LANG", "LC_ALL", "TERM", "TZ", "TMPDIR"] { env[k] = current[k] }
    if rule.home == "user" {
        env["HOME"] = home
    } else {
        let isolated = "\(settingsDir)/home/\(name)"
        if systemMode {
            guard isProtected(isolated) else { die("\(name): \(isolated) must exist and be root-owned (make system-install)", 1) }
        } else {
            try? FileManager.default.createDirectory(atPath: isolated, withIntermediateDirectories: true)
        }
        env["HOME"] = isolated
    }
    for (key, value) in wanted {
        if value.hasPrefix("secret:") {
            let secret = String(value.dropFirst("secret:".count))
            guard let v = getSecret(secret) else { die("secret '\(secret)' is not set; run: approve secret set \(secret)", 1) }
            env[key] = v
        } else {
            env[key] = value
        }
    }
    return env
}

func execReal(_ path: String, _ args: [String], env: [String: String]? = nil) -> Never {
    var cargs: [UnsafeMutablePointer<CChar>?] = ([path] + args).map { strdup($0) }
    cargs.append(nil)
    if let env {
        var cenv: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") }
        cenv.append(nil)
        execve(path, &cargs, &cenv)
    } else {
        execv(path, &cargs)
    }
    die("could not run \(path) (errno \(errno))", 126)
}

/// macOS sudo prompt answered by Touch ID (pam_tid). Used only when the approval itself cannot run.
func sudoFallback(_ name: String, _ argsText: String) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
    p.arguments = ["-k", "-p", "approve: authenticate to run '\(argsText)': ", "--", "true"]
    guard (try? p.run()) != nil else { return false }
    p.waitUntilExit()
    return p.terminationStatus == 0
}

func runWrapped(_ name: String, _ args: [String]) async -> Never {
    let rules = loadRules()
    if rules == nil, FileManager.default.fileExists(atPath: rulesPath) {
        FileHandle.standardError.write("approve: \(rulesPath) is unreadable or not root-owned, so every call asks\n".data(using: .utf8)!)
    }
    let rule = rules?.clis[name]
    let caller = ProcessInfo.processInfo.environment["CLAUDE_CODE_SESSION_ID"] == nil ? "terminal" : "claude"
    if rule?.disabled == true {
        // Gating is off (a link left from before): run the plain command, with your own environment.
        // Never the broker's secrets: those only ever follow an approval or a read-only rule.
        log(name, commandText(name, args), "off", "-", caller)
        guard let real = rule?.path.flatMap({ FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil }) ?? findReal(name) else {
            die("real '\(name)' not found on PATH", 127)
        }
        execReal(real, args)
    }
    let real = resolveReal(name, rule)
    if gateDecision(cli: name, args: args, rules: rules) == "free" {
        log(name, commandText(name, args), "free", "-", caller)
        execReal(real, args, env: brokerEnvironment(name, rule))
    }
    switch await request(cli: name, args: args) {
    case 0:
        execReal(real, args, env: brokerEnvironment(name, rule))
    case 1, 2:
        die("not approved", 1)
    default:
        // 3: Touch ID unavailable and no phone paired. Never for secrets: sudo can be passwordless.
        guard rule?.hasSecrets != true else { die("no Touch ID and no phone, so \(name) cannot get its secrets", 1) }
        guard sudoFallback(name, commandText(name, args)) else { die("authentication failed or declined", 1) }
        execReal(real, args)
    }
}
