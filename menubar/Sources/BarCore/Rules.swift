import Foundation

/// The rules file approve reads (rules.json). Field names match approve exactly.
public struct RulesDoc: Codable, Equatable {
    public struct CLI: Codable, Equatable {
        public var `default`: String?
        public var free: [String]?
        public var path: String?
        public var env: [String: String]?
        public var gatedArgs: [String]?
        public var home: String?
        /// Gating paused: runs without asking; the rules stay for later.
        public var disabled: Bool?
        public var _comment: String?

        public var isOff: Bool { disabled == true }

        public init(free: [String] = [], gatedArgs: [String] = []) {
            self.default = "gated"
            self.free = free
            self.gatedArgs = gatedArgs.isEmpty ? nil : gatedArgs
        }
    }

    public struct Guard: Codable, Equatable { public var hcloudProductionContexts: [String] }
    public struct Approval: Codable, Equatable {
        public var timeoutSeconds: Int?
        public var askOnMac: Bool?
        public init(timeoutSeconds: Int?, askOnMac: Bool?) { self.timeoutSeconds = timeoutSeconds; self.askOnMac = askOnMac }
    }

    public struct Relay: Codable, Equatable {
        public var server: String?
        public init(server: String?) { self.server = server }
    }

    public var _comment: String?
    public var production: [String]?
    public var guardRules: Guard?
    public var approval: Approval?
    public var relay: Relay?
    public var clis: [String: CLI]

    enum CodingKeys: String, CodingKey {
        case _comment, production, approval, relay, clis
        case guardRules = "guard"
    }

    public var timeout: Int { approval?.timeoutSeconds ?? 90 }
    public var askOnMac: Bool { approval?.askOnMac ?? true }

    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try enc.encode(self)
    }
}

/// What approve would do with a call, and why. Same logic as approve's gateDecision.
public struct Verdict: Equatable {
    public enum Kind: Equatable { case runs, asks }
    public var kind: Kind
    public var reason: String
}

/// A read-only pattern matches word by word from the start: each word is a shell glob for the
/// argument in the same place, and only a last word ending in "*" lets more arguments follow.
/// So "* list*" matches `server list -o json` but not `server create --name list`, and "* --help"
/// matches `server --help` but not `exec pod -- sh --help`. An empty pattern matches no arguments.
public func freeMatch(_ pattern: String, _ args: [String]) -> Bool {
    let words = pattern.split(separator: " ").map(String.init)
    guard let last = words.last else { return args.isEmpty }
    guard args.count >= words.count else { return false }
    for (w, a) in zip(words, args) where fnmatch(w, a, 0) != 0 { return false }
    return args.count == words.count || last.hasSuffix("*")
}

/// A gated-argument pattern matches an argument by shell glob. A single-letter flag pattern such as
/// "-u*" also matches that letter inside a cluster of short flags ("-vu URL" sets -u too).
public func gatedArgMatch(_ pattern: String, _ arg: String) -> Bool {
    if fnmatch(pattern, arg, 0) == 0 { return true }
    let p = Array(pattern), a = Array(arg)
    guard p.count == 2 || (p.count == 3 && p[2] == "*"), p[0] == "-", p[1].isLetter,
          a.count > 2, a[0] == "-", a[1] != "-" else { return false }
    return a.dropFirst().prefix { $0.isLetter }.contains(p[1])
}

public func verdict(cli: String, args: [String], rules: RulesDoc) -> Verdict {
    guard let rule = rules.clis[cli] else {
        return Verdict(kind: .asks, reason: "\(cli) has no rules, so every call asks")
    }
    if rule.isOff { return Verdict(kind: .runs, reason: "gating is off for \(cli)") }
    for arg in args {
        for p in rule.gatedArgs ?? [] where gatedArgMatch(p, arg) {
            return Verdict(kind: .asks, reason: "the argument \(arg) always asks (\(p))")
        }
    }
    for p in rule.free ?? [] where freeMatch(p, args) {
        return Verdict(kind: .runs, reason: "matches the read-only pattern \(p)")
    }
    if rule.default == "free" { return Verdict(kind: .runs, reason: "\(cli) runs without asking unless a rule says otherwise") }
    return Verdict(kind: .asks, reason: (rule.free ?? []).isEmpty ? "every \(cli) call asks" : "not in the read-only list")
}

/// Splits a typed command like a shell would for simple cases: spaces, and single or double quotes.
public func shellWords(_ s: String) -> [String] {
    var words: [String] = [], cur = "", quote: Character?, any = false
    for ch in s {
        if let q = quote {
            if ch == q { quote = nil } else { cur.append(ch) }
        } else if ch == "'" || ch == "\"" {
            quote = ch; any = true
        } else if ch == " " || ch == "\t" {
            if any || !cur.isEmpty { words.append(cur); cur = ""; any = false }
        } else {
            cur.append(ch); any = true
        }
    }
    if any || !cur.isEmpty { words.append(cur) }
    return words
}

/// Ready-made read-only lists for common CLIs. Anything not listed asks.
public struct Template: Identifiable, Equatable {
    public var id: String { name }
    public var name: String
    public var summary: String
    public var symbol: String
    public var free: [String]
    public var gatedArgs: [String]
}

public let templates: [Template] = [
    Template(name: "kubectl", summary: "Kubernetes", symbol: "shippingbox",
             free: ["get *", "describe *", "logs *", "top *", "explain *", "api-resources*", "config get-contexts*",
                    "config current-context", "version*", "--help", "* --help"],
             gatedArgs: ["--server*", "--kubeconfig*", "--token*"]),
    Template(name: "terraform", summary: "Infrastructure as code", symbol: "square.stack.3d.up",
             free: ["plan*", "show*", "validate*", "fmt -check*", "state list*", "state show*", "output*", "version", "--help", "* --help"],
             gatedArgs: []),
    Template(name: "aws", summary: "Amazon Web Services", symbol: "cloud",
             free: ["* describe-*", "* list-*", "* get-*", "sts get-caller-identity*", "s3 ls*", "--version", "help", "* help"],
             gatedArgs: ["--endpoint-url*", "--profile*"]),
    Template(name: "gcloud", summary: "Google Cloud", symbol: "cloud",
             free: ["* list*", "* describe *", "config list*", "auth list*", "projects list*", "version", "--help", "* --help"],
             gatedArgs: ["--project*", "--account*"]),
    Template(name: "gh", summary: "GitHub CLI", symbol: "chevron.left.forwardslash.chevron.right",
             free: ["* list*", "* view*", "* status*", "* diff*", "* checks*", "auth status*", "--version", "--help", "* --help"],
             gatedArgs: []),
    Template(name: "glab", summary: "GitLab CLI", symbol: "chevron.left.forwardslash.chevron.right",
             free: ["* list*", "* view*", "* status*", "* diff*", "auth status*", "--version", "--help", "* --help"],
             gatedArgs: []),
    Template(name: "docker", summary: "Containers", symbol: "shippingbox.fill",
             free: ["ps*", "images*", "logs *", "inspect *", "version*", "info*", "stats --no-stream*", "--help", "* --help"],
             gatedArgs: ["-H*", "--host*", "--context*"]),
    Template(name: "helm", summary: "Kubernetes packages", symbol: "helm",
             free: ["list*", "status *", "get *", "history *", "search *", "show *", "version*", "--help", "* --help"],
             gatedArgs: ["--kube-context*", "--kubeconfig*"]),
    Template(name: "vault", summary: "HashiCorp Vault", symbol: "lock.shield",
             free: [], gatedArgs: ["-address*", "--address*"]),
    Template(name: "hcloud", summary: "Hetzner Cloud", symbol: "server.rack",
             free: ["* list*", "* describe*", "context list", "version", "--help", "* --help"],
             gatedArgs: ["--endpoint*", "--config*", "--context*"]),
    Template(name: "doctl", summary: "DigitalOcean", symbol: "drop",
             free: ["* list*", "* get*", "account get*", "version", "--help", "* --help"],
             gatedArgs: ["--api-url*", "-u*", "--access-token*", "-t*", "--config*", "-c*", "--context*"]),
    Template(name: "stripe", summary: "Stripe", symbol: "creditcard",
             free: ["--version", "version", "config *", "login status*", "--help", "* --help"],
             gatedArgs: ["--api-base*", "--api-key*", "--live"]),
    Template(name: "flyctl", summary: "Fly.io", symbol: "paperplane",
             free: ["* list*", "status*", "logs*", "version", "--help", "* --help"], gatedArgs: []),
    Template(name: "wrangler", summary: "Cloudflare Workers", symbol: "flame",
             free: ["whoami", "* list*", "tail*", "--version", "--help", "* --help"], gatedArgs: []),
    Template(name: "psql", summary: "PostgreSQL shell", symbol: "cylinder", free: ["--version", "--help"], gatedArgs: []),
    Template(name: "op", summary: "1Password CLI", symbol: "key", free: ["--version", "whoami*", "--help"], gatedArgs: []),
]

public func template(for name: String) -> Template? { templates.first { $0.name == name } }

/// One line of ~/.approve-gate.log.
public struct LogEntry: Identifiable, Equatable {
    public var id: Int
    public var date: Date?
    public var cli: String
    public var decision: String
    public var via: String
    public var caller: String
    public var command: String
}

public func parseLog(_ text: String, limit: Int = 500) -> [LogEntry] {
    let iso = ISO8601DateFormatter()
    let lines = text.split(separator: "\n").suffix(limit)
    return lines.enumerated().reversed().map { i, line in
        func field(_ k: String) -> String {
            guard let r = line.range(of: " \(k)=") else { return "" }
            return String(line[r.upperBound...].prefix(while: { $0 != " " }))
        }
        let cmd = line.range(of: " args=").map { String(line[$0.upperBound...]) } ?? ""
        return LogEntry(id: i, date: iso.date(from: String(line.prefix(while: { $0 != " " }))),
                        cli: field("cli"), decision: field("decision"), via: field("via"), caller: field("caller"), command: cmd)
    }
}
