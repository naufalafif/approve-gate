// `approve status --json`: everything the menu bar app shows, in one read-only call. No secret
// values, no relay key or topic names: only states, names and paths.

import Foundation

/// Reaches the relay with a poll for nothing new on the request topic. nil if not paired.
func relayCheck(_ c: Config) async -> (ok: Bool, ms: Int, error: String?) {
    let now = Int(Date().timeIntervalSince1970)
    guard let url = URL(string: "\(c.server)/\(c.reqTopic)/json?poll=1&since=\(now + 60)") else {
        return (false, 0, "bad relay address")
    }
    var req = URLRequest(url: url)
    req.timeoutInterval = 8
    let start = Date()
    do {
        let (_, resp) = try await URLSession.shared.data(for: req)
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        return code == 200 ? (true, ms, nil) : (false, ms, code == 429 ? "rate limited (HTTP 429)" : "HTTP \(code)")
    } catch {
        return (false, 0, error.localizedDescription)
    }
}

/// Is `approve hook` registered in the user's Claude Code settings, for Bash and for the file tools?
func hookState() -> [String: Bool] {
    var bash = false, files = false
    let path = "\(home)/.claude/settings.json"
    if let d = FileManager.default.contents(atPath: path),
       let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
       let pre = (o["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]] {
        for entry in pre {
            let matcher = entry["matcher"] as? String ?? ""
            let cmds = (entry["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
            guard cmds.contains(where: { $0.contains("approve") && $0.hasSuffix(" hook") }) else { continue }
            if matcher.split(separator: "|").contains("Bash") { bash = true }
            if matcher.contains("Edit") && matcher.contains("Write") { files = true }
        }
    }
    return ["bash": bash, "fileTools": files]
}

/// Last few decisions from the log: time, cli, decision, device, caller (no arguments).
func recentDecisions(_ count: Int) -> [[String: String]] {
    guard let text = try? String(contentsOfFile: logPath, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").suffix(count).reversed().map { line in
        var out = ["time": String(line.prefix(while: { $0 != " " }))]
        for key in ["cli", "decision", "via", "caller"] {
            if let r = line.range(of: " \(key)=") {
                out[key] = String(line[r.upperBound...].prefix(while: { $0 != " " }))
            }
        }
        return out
    }
}

func statusJSON() async -> Data {
    var s: [String: Any] = ["mode": systemMode ? "system" : "user", "settingsDir": settingsDir, "binary": ownExecutable()]
    // A root-owned install exists, but this is a user copy with its own settings: the two can disagree
    // (for example a phone paired in one and not the other). `make system-install` joins them.
    s["version"] = approveVersion
    s["rootCopyOutdated"] = ProcessInfo.processInfo.environment["APPROVE_ROOT_COPY_OUTDATED"] == "1"
    s["splitInstall"] = !systemMode && FileManager.default.isExecutableFile(atPath: "/usr/local/libexec/approve-gate/approve")
    if let c = loadConfig(), c.phonePublicKey != nil {
        s["paired"] = true
        s["phone"] = c.phoneName ?? "phone"
        s["pairedAt"] = c.pairedAt ?? ""
        s["relay"] = URL(string: c.server)?.host ?? c.server
        let r = await relayCheck(c)
        s["relayOK"] = r.ok
        s["relayMs"] = r.ms
        if let e = r.error { s["relayError"] = e }
    } else {
        s["paired"] = false
    }
    let rules = loadRules()
    s["rulesOK"] = rules != nil
    s["rulesPath"] = rulesPath
    let stored = Set(secretNames())
    s["clis"] = (rules?.clis ?? [:]).keys.sorted().map { name -> [String: Any] in
        let rule = rules?.clis[name]
        let secrets = (rule?.env ?? [:]).values.filter { $0.hasPrefix("secret:") }.map { String($0.dropFirst(7)) }.sorted()
        return ["name": name, "real": rule?.path ?? findReal(name) ?? "",
                "secrets": secrets, "missingSecrets": secrets.filter { !stored.contains($0) },
                "disabled": rule?.disabled == true]
    }
    s["hook"] = hookState()
    s["recent"] = recentDecisions(8)
    return (try? JSONSerialization.data(withJSONObject: s, options: [.sortedKeys, .prettyPrinted])) ?? Data()
}
