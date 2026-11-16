import Foundation

/// What `approve status --json` reports.
public struct GateStatus: Decodable, Equatable {
    public struct CLI: Decodable, Equatable {
        public var name: String
        public var real: String
        public var secrets: [String]
        public var missingSecrets: [String]
        public var disabled: Bool?
    }

    public struct Decision: Decodable, Equatable {
        public var time: String
        public var cli: String?
        public var decision: String?
        public var via: String?
        public var caller: String?
    }

    public var mode: String
    public var paired: Bool
    public var phone: String?
    public var relay: String?
    public var relayOK: Bool?
    public var relayMs: Int?
    public var relayError: String?
    public var splitInstall: Bool?
    public var rootCopyOutdated: Bool?
    public var rulesOK: Bool
    public var rulesPath: String
    public var clis: [CLI]
    public var hook: [String: Bool]
    public var recent: [Decision]
}

/// One line in the menu: a short text, and whether it needs attention.
public struct Finding: Equatable {
    public var text: String
    public var problem: Bool
}

/// What the menu shows, worked out from the status and the login shell's view of each CLI.
public struct Report: Equatable {
    public var findings: [Finding]
    public var problems: Int { findings.filter(\.problem).count }

    /// - Parameters:
    ///   - resolved: CLI name → what `command -v` returns in a login shell ("" when not found).
    ///   - linkDir: the folder the wrapped CLIs should resolve to.
    public init(_ s: GateStatus, resolved: [String: String], linkDir: String) {
        var f: [Finding] = []
        if s.paired {
            let relay = s.relay ?? "relay"
            f.append(Finding(text: "Phone: \(s.phone ?? "paired")", problem: false))
            if s.relayOK == true {
                f.append(Finding(text: "Relay: \(relay), \(s.relayMs ?? 0) ms", problem: false))
            } else {
                f.append(Finding(text: "Relay unreachable: \(relay) (\(s.relayError ?? "no answer"))", problem: true))
            }
        } else {
            f.append(Finding(text: "Phone not paired: Touch ID only (run approve pair)", problem: true))
        }
        if s.rootCopyOutdated == true {
            f.append(Finding(text: "Root-owned copy is out of date: run approve setup", problem: true))
        }
        if s.splitInstall == true {
            f.append(Finding(text: "Two installs with separate settings: run approve setup", problem: true))
        }
        f.append(Finding(text: s.mode == "system" ? "System mode: settings owned by root" : "User mode: settings in your home folder",
                         problem: false))
        let off = s.clis.filter { $0.disabled == true }.map(\.name)
        f.append(s.rulesOK
            ? Finding(text: "Rules: \(s.clis.count) CLIs" + (off.isEmpty ? "" : ", gating off for \(off.joined(separator: ", "))"), problem: false)
            : Finding(text: "Rules unreadable: every call asks", problem: true))
        let bash = s.hook["bash"] ?? false, files = s.hook["fileTools"] ?? false
        if bash && files {
            f.append(Finding(text: "Claude Code hook: on", problem: false))
        } else {
            let missing = [bash ? nil : "commands", files ? nil : "file edits"].compactMap { $0 }.joined(separator: " and ")
            f.append(Finding(text: "Claude Code hook missing for \(missing)", problem: true))
        }
        for cli in s.clis where cli.disabled != true {
            let r = resolved[cli.name] ?? ""
            if r != "\(linkDir)/\(cli.name)" {
                f.append(Finding(text: "\(cli.name) skips the gate: resolves to \(r.isEmpty ? "nothing" : r)", problem: true))
            }
            for m in cli.missingSecrets {
                f.append(Finding(text: "\(cli.name): secret \(m) not set", problem: true))
            }
        }
        findings = f
    }
}

/// "16:37  vault  denied on Mac" for a log entry, in local time.
public func describe(_ d: GateStatus.Decision, timeZone: TimeZone = .current) -> String {
    let iso = ISO8601DateFormatter()
    let out = DateFormatter()
    out.dateFormat = "HH:mm"
    out.timeZone = timeZone
    let when = iso.date(from: d.time).map { out.string(from: $0) } ?? d.time
    let via = switch d.via {
    case "phone": " on phone"
    case "mac": " on Mac"
    default: ""
    }
    return "\(when)  \(d.cli ?? "?")  \(d.decision ?? "?")\(via)"
}

/// Runs a program and returns its standard output. Reads the pipe before waiting, so a large output
/// cannot fill the pipe and block both sides.
public func run(_ path: String, _ args: [String]) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    guard (try? p.run()) != nil else { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8)
}
