// Hook mode: `approve hook`, a Claude Code PreToolUse hook for Bash and the file tools. It reads the
// tool call as JSON on stdin and prints a decision only when it has one:
//   - deny: running a wrapped CLI's real binary by path; changing Approve Gate's own files, its
//     Keychain secrets or the hook itself; destructive hcloud verbs on a production context; direct
//     Hetzner API calls; setting the hcloud token variable inline
//   - ask:  package installs
// Anything else prints nothing, so the call goes through and the wrappers decide. These are pattern
// matches on text: a seatbelt for honest mistakes, not a wall (see docs/details.md).

import Foundation

private let sep = #"(?:^|[;&|(\s"'`])"#
private let denyVerbs = #"^(?:delete|delete-\S+|remove|remove-\S+|detach|detach-\S+|unassign|rebuild|reset|reset-password|shutdown|poweroff|disable-protection|disable-backup|change-type|change-ip-range|replace-rules|set-rules)$"#

private func matches(_ pattern: String, _ text: String) -> Bool {
    text.range(of: pattern, options: .regularExpression) != nil
}

private func firstGroup(_ pattern: String, _ text: String) -> String? {
    guard let re = try? NSRegularExpression(pattern: pattern),
          let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let r = Range(m.range(at: 1), in: text) else { return nil }
    return String(text[r])
}

func activeHcloudContext() -> String? {
    let toml = (try? String(contentsOfFile: "\(home)/.config/hcloud/cli.toml", encoding: .utf8)) ?? ""
    return firstGroup(#"(?m)^active_context\s*=\s*"([^"]*)""#, toml)
}

/// Approve Gate's own files: changing them would loosen the rules, swap the phone, or drop the gate.
let protectedPathPattern = #"\.config/approve-gate|Application Support/ApproveGate(?:/|\b)|libexec/approve-gate|touchid-wrap|(?:~|\$HOME|/Users/[^/\s]+)/bin/approve\b|\.claude/settings(?:\.local)?\.json|wrapper-path\.sh"#
/// Commands that change files (or can run code that does) when given a protected path.
private let writers: Set<String> = ["rm", "mv", "cp", "tee", "ln", "chmod", "chown", "chflags", "install", "truncate",
                                    "ditto", "rsync", "unlink", "touch", "dd", "plutil", "python", "python3", "node",
                                    "swift", "ruby", "perl", "osascript"]

/// Does the shell text write to one of Approve Gate's files? A redirect whose target is protected,
/// or a writing command (or sed -i, defaults write) whose own arguments name a protected path.
/// Reading those files (cat, jq, ls ... | awk 'NR>3') stays allowed.
func writesProtected(_ c: String) -> Bool {
    if matches(#">>?\s*["']?[^\s;|&]*(?:"# + protectedPathPattern + ")", c) { return true }
    let segments = c.components(separatedBy: CharacterSet(charactersIn: ";|&\n"))
    // cd into a protected folder, then write with a relative name (`cd ~/.config/approve-gate && dd of=x`).
    let cdIn = segments.contains { seg in
        let w = seg.split(whereSeparator: \.isWhitespace)
        return ["cd", "pushd"].contains(w.first.map(String.init) ?? "") && matches(protectedPathPattern, seg)
    }
    if cdIn {
        if c.contains(">") { return true }
        for seg in segments {
            var w = seg.split(whereSeparator: \.isWhitespace).map(String.init)
            while let f = w.first, ["sudo", "env", "exec", "command", "nohup", "time", "nice", "xargs"].contains(f) || f.contains("=") { w.removeFirst() }
            guard let cmd = w.first.map({ ($0 as NSString).lastPathComponent }) else { continue }
            if writers.contains(cmd) || (cmd == "sed" && w.contains { $0.hasPrefix("-i") }) || (cmd == "defaults" && w.dropFirst().first == "write") { return true }
        }
    }
    for seg in segments where matches(protectedPathPattern, seg) {
        var words = seg.split(whereSeparator: \.isWhitespace).map(String.init)
        while let w = words.first, ["sudo", "env", "exec", "command", "nohup", "time", "nice", "xargs"].contains(w)
            || w.hasPrefix("-") || w.contains("=") {
            words.removeFirst()
        }
        guard let cmd = words.first.map({ ($0 as NSString).lastPathComponent }) else { continue }
        // cp and ditto only write their last argument: copying a protected file out is a read.
        if ["cp", "ditto"].contains(cmd) {
            let args = quotedWords(seg).drop { $0 != words.first }.dropFirst()
            if let dest = args.last(where: { !$0.hasPrefix("-") }), matches(protectedPathPattern, dest) { return true }
            continue
        }
        if writers.contains(cmd) { return true }
        if cmd == "sed", words.contains(where: { $0.hasPrefix("-i") }) { return true }
        if cmd == "defaults", words.dropFirst().first == "write" { return true }
    }
    return false
}
/// Words of a command, keeping quoted parts together ("a b" is one word, quotes removed).
private func quotedWords(_ s: String) -> [String] {
    var words: [String] = [], cur = "", quote: Character?, any = false
    for ch in s {
        if let q = quote {
            if ch == q { quote = nil } else { cur.append(ch) }
        } else if ch == "'" || ch == "\"" {
            quote = ch; any = true
        } else if ch.isWhitespace {
            if any { words.append(cur); cur = ""; any = false }
        } else {
            cur.append(ch); any = true
        }
    }
    if any { words.append(cur) }
    return words
}

/// A command word, after any separators, wrappers (sudo, env, exec...) and VAR=value prefixes.
private let commandStart = #"(?:^|[;&|(`\n]|\$\()\s*(?:(?:sudo|exec|env|command|nohup|time|nice|xargs)\s+(?:-\S+\s+)*)*(?:[A-Za-z_][A-Za-z0-9_]*=\S*\s+)*"#

/// nil means no opinion. Otherwise (decision, reason), decision is "deny" or "ask".
func guardDecision(_ command: String, productionContexts: Set<String>, activeContext: String?,
                   wrapped: [String] = ["vault", "hcloud", "doctl", "kcadm", "rd", "stripe"]) -> (String, String)? {
    let c = command
    if c.contains("disableAllHooks") {
        return ("deny", "turns off Claude Code hooks, which removes the Approve Gate check")
    }
    let names = wrapped.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
    if !names.isEmpty, let re = try? NSRegularExpression(pattern: commandStart + #"(\S*/)("# + names + #")(?=$|[\s;&|)`])"#) {
        for m in re.matches(in: c, range: NSRange(c.startIndex..., in: c)) {
            guard let dir = Range(m.range(at: 1), in: c), let cli = Range(m.range(at: 2), in: c),
                  !c[dir].contains("touchid-wrap/") else { continue }
            return ("deny", "runs the real \(c[cli]) by its path (\(c[dir])\(c[cli])), which skips Approve Gate; use plain `\(c[cli])`")
        }
    }
    if writesProtected(c) {
        return ("deny", "changes Approve Gate's own files (rules, pairing, links, binary, or the Claude Code settings that hold the hook)")
    }
    // Reading a secret asks (you approve the read); changing or deleting one stays blocked.
    if matches(#"\bsecurity\s+find-generic-password\b.*approve-gate"#, c) {
        return ("ask", "reads one of Approve Gate's Keychain secrets")
    }
    if matches(#"\bsecurity\s+\S+.*approve-gate"#, c) {
        return ("deny", "changes Approve Gate's Keychain secrets")
    }
    if c.contains("api.hetzner.cloud") {
        return ("deny", "calls the Hetzner API directly, which skips the hcloud context guard")
    }
    if matches(sep + "HCLOUD_TOKEN=", c) {
        return ("deny", "sets HCLOUD_TOKEN, which skips the hcloud context guard")
    }
    let envContext = firstGroup(#"HCLOUD_CONTEXT=["']?([\w.-]+)"#, c)
    if let re = try? NSRegularExpression(pattern: sep + #"hcloud\s+([^;&|\n`]*)"#) {
        for m in re.matches(in: c, range: NSRange(c.startIndex..., in: c)) {
            guard let r = Range(m.range(at: 1), in: c) else { continue }
            let args = String(c[r])
            let context = firstGroup(#"--context[=\s]+["']?([\w.-]+)"#, args) ?? envContext ?? activeContext ?? ""
            let rest = args.replacingOccurrences(of: #"--context[=\s]+\S+"#, with: " ", options: .regularExpression)
            // Positional words only. Splitting this way never yields an empty first word, which is
            // how the old bash hook missed `hcloud --context prod server delete`.
            let words = rest.split(whereSeparator: \.isWhitespace).map(String.init).filter { !$0.hasPrefix("-") }
            guard let resource = words.first, !["context", "version", "completion", "help"].contains(resource) else { continue }
            let verb = words.count > 1 ? words[1] : ""
            guard productionContexts.contains(context) else { continue }
            if matches(denyVerbs, verb) {
                return ("deny", "runs \"hcloud \(resource) \(verb)\" on the production context \(context)")
            }
        }
    }
    if matches(sep + #"(?:brew|pipx?|pip3|gem|cargo|apt|apt-get|port)\s+install\b"#, c)
        || matches(sep + #"npm\s+(?:install|i)\s+(?:.*\s)?(?:-g|--global)\b"#, c)
        || matches(sep + #"uv\s+(?:tool|pip)\s+install\b"#, c) {
        return ("ask", "installs a package")
    }
    return nil
}

/// `approve hook [--rules PATH] [--hcloud-active CTX]`. The flags exist for tests: they only change
/// what this one invocation decides, and Claude Code runs the hook with the fixed command in settings.
/// File tools (Edit, Write, MultiEdit, NotebookEdit): no edits to Approve Gate's files, and no edit
/// of a Claude Code settings file that removes the hook or turns hooks off.
func fileToolDecision(_ tool: [String: Any]) -> (String, String)? {
    guard let raw = (tool["file_path"] ?? tool["notebook_path"]) as? String else { return nil }
    let expanded = (raw as NSString).expandingTildeInPath
    let parent = realPath((expanded as NSString).deletingLastPathComponent)
    let resolved = realPath(expanded)
        ?? parent.map { ($0 as NSString).appendingPathComponent((expanded as NSString).lastPathComponent) }
        ?? expanded
    var texts: [String] = []
    for key in ["content", "new_string", "new_source"] { if let t = tool[key] as? String { texts.append(t) } }
    for e in (tool["edits"] as? [[String: Any]]) ?? [] { if let t = e["new_string"] as? String { texts.append(t) } }
    if texts.contains(where: { $0.contains("disableAllHooks") }) {
        return ("deny", "turns off Claude Code hooks, which removes the Approve Gate check")
    }
    if resolved.hasSuffix("/.claude/settings.json") || resolved.hasSuffix("/.claude/settings.local.json") {
        let before = (try? String(contentsOfFile: resolved, encoding: .utf8)) ?? ""
        var removed = false
        if let content = tool["content"] as? String {
            removed = before.contains("approve hook") && !content.contains("approve hook")
        }
        var pairs: [(String, String)] = []
        if let o = tool["old_string"] as? String, let n = tool["new_string"] as? String { pairs.append((o, n)) }
        for e in (tool["edits"] as? [[String: Any]]) ?? [] {
            if let o = e["old_string"] as? String, let n = e["new_string"] as? String { pairs.append((o, n)) }
        }
        if pairs.contains(where: { $0.0.contains("approve hook") && !$0.1.contains("approve hook") }) { removed = true }
        return removed ? ("deny", "removes the Approve Gate hook from \(raw)") : nil
    }
    for p in [expanded, resolved] where matches(protectedPathPattern, p) {
        return ("deny", "changes Approve Gate's own files (\(raw))")
    }
    return nil
}

func runHook(_ argv: [String]) {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    guard let obj = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
          let tool = obj["tool_input"] as? [String: Any] else { return }
    let rules = loadRules(flagValue(argv, "--rules"))
    let result: (String, String)?
    if let command = tool["command"] as? String {
        // No rules, no production contexts: the hook still blocks the rest, and the wrappers still ask.
        let prod = Set(rules?.guardRules?.hcloudProductionContexts ?? [])
        let active = flagValue(argv, "--hcloud-active") ?? activeHcloudContext()
        let wrapped = rules.map { r in r.clis.keys.filter { r.clis[$0]?.disabled != true } } ?? ["vault", "hcloud", "doctl", "kcadm", "rd", "stripe"]
        result = guardDecision(command, productionContexts: prod, activeContext: active, wrapped: wrapped)
    } else {
        result = fileToolDecision(tool)
    }
    guard let (decision, reason) = result else { return }
    let message = decision == "deny"
        ? "Blocked by Approve Gate: this command \(reason). Don't retry or work around it. Tell the user the exact command and why, and let them run it themselves if they agree."
        : "This command \(reason). Confirm before it runs."
    let out: [String: Any] = ["hookSpecificOutput": [
        "hookEventName": "PreToolUse", "permissionDecision": decision, "permissionDecisionReason": message,
    ]]
    if let d = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]) {
        FileHandle.standardOutput.write(d)
        FileHandle.standardOutput.write("\n".data(using: .utf8)!)
    }
}
