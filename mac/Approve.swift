// Approval core: one approval per gated CLI call, by Touch ID on this Mac or by fingerprint on
// the paired Android phone, whichever answers first. Both prompts show what is being approved.
//
// Transport: two random ntfy topics (requests to the phone, answers back). Every message is
// AES-256-GCM encrypted with a key shared at pairing, so the relay only sees ciphertext.
// A phone approval is an ECDSA P-256 signature, made by a key in the phone's secure hardware
// that only unlocks with a fingerprint, over the exact request bytes. The Mac checks it
// against the public key saved at pairing, so a relay or an attacker cannot forge a yes.

import AppKit
import CoreImage
import CryptoKit
import Foundation
import LocalAuthentication

// MARK: - Config

struct Config: Codable {
    var server: String
    var reqTopic: String
    var resTopic: String
    var key: String
    var phonePublicKey: String?
    var phoneName: String?
    var pairedAt: String?
}

let home = FileManager.default.homeDirectoryForCurrentUser.path
#if APPROVE_TEST
// Test build only (`make test-build`, mac/approve-test): its own folder, so tests can pair a fake
// phone without touching the real pairing. The shipped binary has no way to change the folder,
// since a caller that could point it elsewhere could pair a fake phone and approve itself.
let configDir = ProcessInfo.processInfo.environment["APPROVE_TEST_DIR"] ?? "\(home)/.config/approve-gate-test"
let logPath = "\(configDir)/approve.log"
#else
let configDir = "\(home)/.config/approve-gate"
let logPath = "\(home)/.approve-gate.log"
#endif
/// From the rules ("approval": {"timeoutSeconds": N}), default 90 s, kept within 10-300 s.
/// APPROVE_TIMEOUT can only shorten it: a shorter wait just fails closed sooner.
let timeoutSeconds: Double = {
    let configured = Double(loadRules()?.approval?.timeoutSeconds ?? 90)
    let env = Double(ProcessInfo.processInfo.environment["APPROVE_TIMEOUT"] ?? "") ?? .infinity
    return min(300, max(10, min(configured, env)))
}()

/// The Mac Touch ID prompt, unless the rules turn it off (phone only) or a test asks to skip it.
var askOnMac: Bool {
    ProcessInfo.processInfo.environment["APPROVE_NO_MAC"] != "1" && (loadRules()?.approval?.askOnMac ?? true)
}

func loadConfig() -> Config? {
    guard let d = readSettings(configPath) else { return nil }
    return try? JSONDecoder().decode(Config.self, from: d)
}

func saveConfig(_ c: Config) throws {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    // The code comes first: the phone name is chosen by whoever answered, so it goes last and short.
    let what = c.phonePublicKey.map { "pairing code \(pairingCode($0)): approve only if your phone shows this code (it says it is \(String((c.phoneName ?? "a phone").prefix(40))))" }
        ?? "save the pairing with \(c.phoneName ?? "a phone")"
    try writeSettings(try enc.encode(c), configPath, reason: what)
}

/// Six-digit code for a phone's public key (its Base64 text). The phone shows the code of its own
/// key and the Mac's approval prompt shows the code of the key it is about to save, so a key paired
/// by another program shows a different code. Same formula as the Android app (Gate.pairingCode).
func pairingCode(_ publicKeyB64: String) -> String {
    let h = Array(SHA256.hash(data: Data("approvegate-pair-code:\(publicKeyB64)".utf8)))
    let n = (UInt32(h[0]) << 24 | UInt32(h[1]) << 16 | UInt32(h[2]) << 8 | UInt32(h[3])) % 1_000_000
    let code = String(format: "%06u", n)
    return String(code.prefix(3)) + " " + String(code.suffix(3))
}

func die(_ msg: String, _ code: Int32 = 2) -> Never {
    FileHandle.standardError.write("approve: \(msg)\n".data(using: .utf8)!)
    exit(code)
}

func randomToken(_ bytes: Int) -> String {
    var b = [UInt8](repeating: 0, count: bytes)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes, &b) == errSecSuccess else { die("no secure random bytes available", 1) }
    return b.map { String(format: "%02x", $0) }.joined()
}

// MARK: - Crypto and relay

func seal(_ plain: Data, _ c: Config) throws -> String {
    let key = SymmetricKey(data: Data(base64Encoded: c.key)!)
    return try AES.GCM.seal(plain, using: key).combined!.base64EncodedString()
}

func unseal(_ b64: String, _ c: Config) -> Data? {
    guard let d = Data(base64Encoded: b64),
          let box = try? AES.GCM.SealedBox(combined: d) else { return nil }
    return try? AES.GCM.open(box, using: SymmetricKey(data: Data(base64Encoded: c.key)!))
}

func publish(_ topic: String, _ obj: [String: Any], _ c: Config) async throws {
    let plain = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    try await publishRaw(topic, plain, c)
}

func publishRaw(_ topic: String, _ plain: Data, _ c: Config) async throws {
    var req = URLRequest(url: URL(string: "\(c.server)/\(topic)")!)
    req.httpMethod = "POST"
    req.httpBody = try seal(plain, c).data(using: .utf8)
    req.timeoutInterval = 15
    let (_, resp) = try await URLSession.shared.data(for: req)
    if let h = resp as? HTTPURLResponse, h.statusCode >= 300 {
        throw NSError(domain: "approve", code: h.statusCode,
                      userInfo: [NSLocalizedDescriptionKey: "relay returned HTTP \(h.statusCode)"])
    }
}

/// Streams decrypted messages from a topic, starting at `since` (unix seconds).
func subscribe(_ topic: String, since: Int, _ c: Config) -> AsyncStream<[String: Any]> {
    AsyncStream { cont in
        let task = Task {
            var since = since
            while !Task.isCancelled {
                do {
                    var req = URLRequest(url: URL(string: "\(c.server)/\(topic)/json?since=\(since)")!)
                    req.timeoutInterval = 120
                    let (bytes, _) = try await URLSession.shared.bytes(for: req)
                    for try await line in bytes.lines {
                        guard let d = line.data(using: .utf8),
                              let ev = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                              ev["event"] as? String == "message",
                              let body = ev["message"] as? String else { continue }
                        if let t = ev["time"] as? Int { since = t }
                        guard let plain = unseal(body, c),
                              var obj = try? JSONSerialization.jsonObject(with: plain) as? [String: Any]
                        else { continue }
                        obj["_raw"] = plain
                        cont.yield(obj)
                    }
                } catch {
                    if Task.isCancelled { break }
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
            cont.finish()
        }
        cont.onTermination = { _ in task.cancel() }
    }
}

func verify(_ sigB64: String?, over data: Data, _ c: Config) -> Bool {
    guard let sigB64, let sigD = Data(base64Encoded: sigB64),
          let pkB64 = c.phonePublicKey, let pkD = Data(base64Encoded: pkB64),
          let pk = try? P256.Signing.PublicKey(derRepresentation: pkD),
          let raw = derToRaw(sigD),
          let sig = try? P256.Signing.ECDSASignature(rawRepresentation: raw) else { return false }
    return pk.isValidSignature(sig, for: data)
}

/// ECDSA DER (SEQUENCE { INTEGER r, INTEGER s }) to the 64-byte r||s form. Lenient about
/// non-minimal integer padding, which some secure chips emit and CryptoKit's DER parser rejects.
func derToRaw(_ d: Data) -> Data? {
    let b = [UInt8](d)
    var i = 0
    func len() -> Int? {
        guard i < b.count else { return nil }
        var n = Int(b[i]); i += 1
        if n & 0x80 != 0 {
            let k = n & 0x7f; n = 0
            for _ in 0..<k { guard i < b.count else { return nil }; n = n << 8 | Int(b[i]); i += 1 }
        }
        return n
    }
    func int() -> Data? {
        guard i < b.count, b[i] == 0x02 else { return nil }
        i += 1
        guard let n = len(), i + n <= b.count else { return nil }
        var v = Array(b[i..<i + n]); i += n
        while v.count > 32, v.first == 0 { v.removeFirst() }
        guard v.count <= 32 else { return nil }
        return Data(repeating: 0, count: 32 - v.count) + Data(v)
    }
    guard b.first == 0x30 else { return nil }
    i = 1
    guard len() != nil, let r = int(), let s = int() else { return nil }
    return r + s
}

// MARK: - Context: what is being approved

func sessionTitle(_ id: String) -> String? {
    let base = "\(home)/Library/Application Support/Claude/claude-code-sessions"
    let fm = FileManager.default
    for a in (try? fm.contentsOfDirectory(atPath: base)) ?? [] {
        for b in (try? fm.contentsOfDirectory(atPath: "\(base)/\(a)")) ?? [] {
            let p = "\(base)/\(a)/\(b)/local_\(id).json"
            if let d = fm.contents(atPath: p),
               let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let t = o["title"] as? String, !t.isEmpty { return t }
        }
    }
    return nil
}

func flagValue(_ args: [String], _ name: String) -> String? {
    for (i, a) in args.enumerated() {
        if a == name, i + 1 < args.count { return args[i + 1] }
        if a.hasPrefix(name + "=") { return String(a.dropFirst(name.count + 1)) }
    }
    return nil
}

/// Which environment the command hits, as far as it can be told without calling anything.
func target(cli: String, args: [String]) -> String {
    let env = ProcessInfo.processInfo.environment
    switch cli {
    case "vault":
        return env["VAULT_ADDR"] ?? "VAULT_ADDR not set"
    case "hcloud":
        if let c = flagValue(args, "--context") ?? env["HCLOUD_CONTEXT"] { return "context \(c)" }
        let toml = (try? String(contentsOfFile: "\(home)/.config/hcloud/cli.toml", encoding: .utf8)) ?? ""
        for line in toml.split(separator: "\n") where line.hasPrefix("active_context") {
            return "context " + line.split(separator: "=").last!.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"")) + " (active)"
        }
        return "hcloud active context"
    case "kcadm":
        let cfg = flagValue(args, "--config") ?? ""
        if cfg.contains("kcadm-prod") { return "Keycloak PRODUCTION" }
        if cfg.contains("kcadm-stg") { return "Keycloak staging" }
        return flagValue(args, "--server") ?? "Keycloak local"
    case "rd":
        return env["RD_URL"] ?? "Rundeck"
    case "doctl":
        return "context " + (flagValue(args, "--context") ?? env["DIGITALOCEAN_CONTEXT"] ?? "default")
    case "stripe":
        return args.contains("--live") ? "Stripe LIVE" : "Stripe test mode"
    default:
        return ""
    }
}

/// A target counts as production when it contains one of the markers in rules.json
/// ("production": [...]), by default "prod" and "live". Shown in red on both devices.
func isProduction(_ t: String) -> Bool {
    let l = t.lowercased()
    let markers = loadRules()?.production ?? ["prod", "live"]
    return markers.contains { !$0.isEmpty && l.contains($0.lowercased()) }
}

/// Control and invisible formatting characters (newlines, bidi overrides, zero-width) shown as
/// \u{…}, so a command cannot look different on the prompt from what runs.
func visible(_ s: String) -> String {
    var out = ""
    for u in s.unicodeScalars {
        switch u.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .unassigned, .surrogate:
            out += "\\u{" + String(u.value, radix: 16) + "}"
        default:
            out.unicodeScalars.append(u)
        }
    }
    return out
}

func shellQuote(_ a: String) -> String {
    let a = visible(a)
    if a.range(of: "^[A-Za-z0-9_./:=@%+,-]+$", options: .regularExpression) != nil { return a }
    return "'" + a.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

// MARK: - QR code

func qrModules(_ text: String) -> [[Bool]] {
    let f = CIFilter(name: "CIQRCodeGenerator")!
    f.setValue(text.data(using: .utf8), forKey: "inputMessage")
    f.setValue("M", forKey: "inputCorrectionLevel")
    let img = f.outputImage!
    let ctx = CIContext()
    let cg = ctx.createCGImage(img, from: img.extent)!
    let rep = NSBitmapImageRep(cgImage: cg)
    var rows: [[Bool]] = []
    for y in 0..<rep.pixelsHigh {
        var row: [Bool] = []
        for x in 0..<rep.pixelsWide { row.append((rep.colorAt(x: x, y: y)?.brightnessComponent ?? 1) < 0.5) }
        rows.append(row)
    }
    return rows
}

func printQR(_ m: [[Bool]]) {
    let quiet = 2, w = m[0].count + quiet * 2
    func dark(_ x: Int, _ y: Int) -> Bool {
        let xx = x - quiet, yy = y - quiet
        return yy >= 0 && yy < m.count && xx >= 0 && xx < m[0].count && m[yy][xx]
    }
    var y = 0
    while y < m.count + quiet * 2 {
        var line = ""
        for x in 0..<w {
            switch (dark(x, y), dark(x, y + 1)) {
            case (true, true): line += " "
            case (true, false): line += "▄"
            case (false, true): line += "▀"
            case (false, false): line += "█"
            }
        }
        print(line)
        y += 2
    }
}

func writeQRPNG(_ m: [[Bool]], _ path: String) {
    let scale = 10, quiet = 4, n = m.count + quiet * 2
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: n * scale, pixelsHigh: n * scale,
                               bitsPerSample: 8, samplesPerPixel: 1, hasAlpha: false, isPlanar: false,
                               colorSpaceName: .deviceWhite, bytesPerRow: 0, bitsPerPixel: 0)!
    // Write the grey bytes directly: setColor on a grey bitmap logs two colorspace warnings per pixel.
    guard let bytes = rep.bitmapData else { return }
    for py in 0..<n * scale {
        for px in 0..<n * scale {
            let x = px / scale - quiet, y = py / scale - quiet
            let d = y >= 0 && y < m.count && x >= 0 && x < m.count && m[y][x]
            bytes[py * rep.bytesPerRow + px] = d ? 0 : 255
        }
    }
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}

// MARK: - Commands

/// Pairing, removing a pairing, changing secrets: an approval when a phone is already paired, so a
/// script or agent cannot swap in a phone it controls. In system mode the change is also saved
/// through sudo or the macOS admin prompt, so the menu bar app may run it. In user mode, where
/// nothing else stands in the way, it must come from a real terminal.
/// A real terminal on stdin and stdout. The test build can pretend one (APPROVE_TEST_TERMINAL=1).
func hasTerminal() -> Bool {
    #if APPROVE_TEST
    if ProcessInfo.processInfo.environment["APPROVE_TEST_TERMINAL"] == "1" { return true }
    #endif
    return isatty(0) == 1 && isatty(1) == 1
}

func guardPairingChange(_ action: String, terminalCanApprove: Bool = true) async {
    #if APPROVE_TEST
    let needTerminal = ProcessInfo.processInfo.environment["APPROVE_TEST_TTY"] == "1"
    #else
    let needTerminal = !systemMode
    #endif
    if needTerminal, isatty(0) != 1 {
        die("run `approve \(action)` yourself in a terminal; scripts and agents cannot change the pairing", 1)
    }
    // Always ask, paired or not: unpaired, a program that pairs its own key would approve everything
    // after that. The prompt shows the full command (server, --link, …), not just the action.
    let paired = loadConfig().map { $0.phonePublicKey != nil } ?? false
    if paired { print("Changing the pairing with \(loadConfig()?.phoneName ?? "the phone") needs your approval first.") }
    fflush(stdout)
    switch await request(cli: "approve", args: Array(CommandLine.arguments.dropFirst())) {
    case 0: settingsChangeApproved = true
    // No Touch ID and not paired: typing it in a terminal is the approval, because the save that
    // follows still goes through sudo or the admin prompt. Secret writes have no such second step.
    case 3 where terminalCanApprove && hasTerminal(): break
    case 3 where terminalCanApprove: die("`approve \(action)` needs Touch ID or a terminal; run it yourself in a terminal", 1)
    case 3: die("`approve \(action)` needs Touch ID or the phone; neither is available", 1)
    default: die("not approved; nothing changed", 1)
    }
}

func pair(server: String, png: Bool, showLink: Bool) async {
    // The link and QR hold the pairing key, and a program running as you can read them (its own
    // output, pair.png). That is why saving a phone's key asks again, showing that phone's code.
    await guardPairingChange("pair")
    // The new key stays in memory until the phone has answered: nothing on disk for another
    // process to read and race the real phone with.
    var c = Config(server: server, reqTopic: "ag-" + randomToken(16), resTopic: "ag-" + randomToken(16),
                   key: Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64EncodedString())
    let keyB64url = c.key.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    var comps = URLComponents()
    comps.scheme = "approvegate"; comps.host = "pair"
    comps.queryItems = [.init(name: "s", value: c.server), .init(name: "q", value: c.reqTopic),
                        .init(name: "r", value: c.resTopic), .init(name: "k", value: keyB64url),
                        .init(name: "m", value: Host.current().localizedName ?? "Mac")]
    let link = comps.url!.absoluteString
    let m = qrModules(link)
    print("Scan this with the Approve Gate app (Scan pairing code):\n")
    printQR(m)
    // The QR code and the link both contain the pairing key: show them only when asked.
    let pngPath = "\(configDir)/pair.png"
    if png {
        try? FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        writeQRPNG(m, pngPath)
        print("\nQR image (deleted once paired): \(pngPath)")
    }
    if showLink {
        print("Phone on adb? Run: adb shell am start -a android.intent.action.VIEW -d '\(link)'")
        print("PAIRLINK \(link)")
    }
    print("\nWaiting up to 5 minutes for the phone...")
    fflush(stdout)

    let start = Int(Date().timeIntervalSince1970) - 5
    let done: Bool = await withTaskGroup(of: Bool.self) { g in
        g.addTask {
            for await msg in subscribe(c.resTopic, since: start, c) {
                guard msg["type"] as? String == "pair", let pk = msg["publicKey"] as? String else { continue }
                var test = c
                test.phonePublicKey = pk
                let challenge = "approvegate-pair:\(c.resTopic)".data(using: .utf8)!
                guard verify(msg["sig"] as? String, over: challenge, test) else {
                    print("Ignored a pairing reply with a bad signature."); continue
                }
                test.phoneName = visible(String((msg["name"] as? String ?? "phone").prefix(40)))
                test.pairedAt = ISO8601DateFormatter().string(from: Date())
                print("A phone answered with pairing code \(pairingCode(pk)) (it says it is \(test.phoneName ?? "phone")).")
                print("Approve only if your phone shows the same code.")
                fflush(stdout)
                // Ask again for this exact key, even if starting the pairing was approved.
                settingsChangeApproved = false
                do { try saveConfig(test) } catch {
                    print("Not paired with that phone (\(error.localizedDescription)). Still waiting for your phone...")
                    fflush(stdout)
                    continue
                }
                c = test
                try? await publish(c.reqTopic, ["type": "paired", "mac": Host.current().localizedName ?? "Mac",
                                                "code": pairingCode(pk)], c)
                return true
            }
            return false
        }
        g.addTask { try? await Task.sleep(nanoseconds: 300_000_000_000); return false }
        let r = await g.next() ?? false
        g.cancelAll()
        return r
    }
    try? FileManager.default.removeItem(atPath: pngPath)
    if done {
        print("Paired with \(c.phoneName ?? "phone"). Gated commands now ask on both this Mac and the phone.")
    } else {
        die("no phone answered within 5 minutes; run `approve pair` again")
    }
}

enum Outcome { case approved(String), denied(String), timeout }

func touchID(_ ctx: LAContext, _ reason: String) async -> Outcome? {
    #if APPROVE_TEST
    // The test build never shows a real Touch ID prompt. APPROVE_TEST_MAC plays the Mac's answer:
    // approve, deny, or (unset) Touch ID unavailable. The reason goes to stderr so tests can check it.
    FileHandle.standardError.write("TESTMAC \(reason.replacingOccurrences(of: "\n", with: " | "))\n".data(using: .utf8)!)
    switch ProcessInfo.processInfo.environment["APPROVE_TEST_MAC"] {
    case "approve": return .approved("mac")
    case "deny": return .denied("mac")
    default: return nil
    }
    #else
    return await withCheckedContinuation { cont in
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, err in
            if ok { cont.resume(returning: .approved("mac")); return }
            let code = (err as? LAError)?.code
            if code == .userCancel { cont.resume(returning: .denied("mac")); return }
            cont.resume(returning: nil) // unavailable, or cancelled because the phone answered
        }
    }
    #endif
}

func log(_ cli: String, _ argsText: String, _ decision: String, _ via: String, _ caller: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) cli=\(cli) decision=\(decision) via=\(via) caller=\(caller) args=\(argsText)\n"
    if let h = FileHandle(forWritingAtPath: logPath) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile()
    } else {
        FileManager.default.createFile(atPath: logPath, contents: line.data(using: .utf8),
                                       attributes: [.posixPermissions: 0o600])
    }
}

/// The command as one shell-quoted line for prompts and the log. Very long commands are cut with
/// a marker that says how much is hidden, so nothing dangerous can sit unseen behind a plain "…".
func commandText(_ cli: String, _ args: [String]) -> String {
    let text = ([cli] + args).map(shellQuote).joined(separator: " ")
    let limit = 4000
    guard text.count > limit else { return text }
    return String(text.prefix(limit)) + " [… \(text.count - limit) MORE CHARACTERS NOT SHOWN]"
}

/// `summary`, for a settings change, replaces the "run …" line with what the change does, and is
/// also the reason the phone shows (a caller's APPROVE_REASON cannot replace it).
func request(cli: String, args: [String], summary: String? = nil) async -> Int32 {
    let env = ProcessInfo.processInfo.environment
    let argsText = commandText(cli, args)
    let tgt = target(cli: cli, args: args)
    let prod = isProduction(tgt)
    var callerKind = "terminal", callerLabel = "Your terminal"
    if let sid = env["CLAUDE_CODE_SESSION_ID"] {
        callerKind = "claude"
        // The title comes from a file the caller can write: escape it so it cannot add prompt lines.
        callerLabel = "Claude: " + visible(String((sessionTitle(sid) ?? "session \(sid.prefix(8))").prefix(80)))
    }
    // The caller sets APPROVE_REASON: escape it so it cannot add fake lines to the prompt.
    let reason = summary ?? env["APPROVE_REASON"].map { visible(String($0.prefix(300))) }
    let cwd = FileManager.default.currentDirectoryPath.replacingOccurrences(of: home, with: "~")
    let now = Int(Date().timeIntervalSince1970)

    // Touch ID dialog text: macOS shows it under "<app> wants to …".
    var macReason = "run \(argsText.count > 140 ? String(argsText.prefix(140)) + "… (\(argsText.count) characters; full text on the phone and in ~/.approve-gate.log)" : argsText)"
    if !tgt.isEmpty { macReason += "\nTarget: \(tgt)\(prod ? " ⚠️" : "")" }
    if let summary { macReason = "\(summary)\nCommand: \(argsText.prefix(140))" }
    macReason += "\nFrom: \(callerLabel)"
    if let reason, summary == nil { macReason += "\nWhy (given by the caller): \(reason)" }

    let ctx = LAContext()
    guard let c = loadConfig(), c.phonePublicKey != nil else {
        // Not paired: Touch ID only, with the same timeout, so a locked Mac does not hang the call.
        let local: Outcome? = await withTaskGroup(of: Outcome?.self) { g in
            g.addTask { await touchID(ctx, macReason) }
            g.addTask { try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1e9)); return .timeout }
            let r = await g.next() ?? nil
            ctx.invalidate()
            g.cancelAll()
            return r
        }
        switch local {
        case .approved: log(cli, argsText, "approved", "mac", callerKind); return 0
        case .denied: log(cli, argsText, "denied", "mac", callerKind); return 1
        case .timeout:
            log(cli, argsText, "timeout", "-", callerKind)
            FileHandle.standardError.write("approve: no answer within \(Int(timeoutSeconds))s\n".data(using: .utf8)!)
            return 2
        default:
            // Touch ID could not run (no sensor, lid closed): exit 3 so the wrapper uses sudo.
            log(cli, argsText, "unavailable", "-", callerKind); return 3
        }
    }

    let id = UUID().uuidString.lowercased()
    var req: [String: Any] = [
        "type": "request", "id": id, "cli": cli, "command": argsText, "target": tgt,
        "production": prod, "caller": callerLabel, "callerKind": callerKind, "cwd": cwd,
        "host": Host.current().localizedName ?? "Mac", "createdAt": now,
        "expiresAt": now + Int(timeoutSeconds),
    ]
    if let reason { req["reason"] = reason }
    let plain = try! JSONSerialization.data(withJSONObject: req, options: [.sortedKeys])

    let outcome: Outcome = await withTaskGroup(of: Outcome?.self) { g in
        if askOnMac { g.addTask { await touchID(ctx, macReason) } }
        g.addTask {
            // Subscribe first, then publish, so a fast answer is not missed.
            let stream = subscribe(c.resTopic, since: now - 2, c)
            do { try await publishRaw(c.reqTopic, plain, c) } catch {
                FileHandle.standardError.write("approve: could not reach the phone relay (\(error.localizedDescription)); Touch ID still works\n".data(using: .utf8)!)
                return nil
            }
            for await msg in stream {
                guard msg["type"] as? String == "response", msg["id"] as? String == id else { continue }
                if msg["decision"] as? String == "approve" {
                    if verify(msg["sig"] as? String, over: Data(SHA256.hash(data: plain)), c)
                        || verify(msg["sig"] as? String, over: plain, c) { return .approved("phone") }
                    FileHandle.standardError.write("approve: ignored a phone approval with a bad signature\n".data(using: .utf8)!)
                    // Keep the request and signature (no secrets: command text and a one-request
                    // signature) so a mismatch can be diagnosed offline.
                    let dbg: [String: Any] = ["plain": plain.base64EncodedString(), "sig": msg["sig"] as? String ?? ""]
                    if let d = try? JSONSerialization.data(withJSONObject: dbg) {
                        FileManager.default.createFile(atPath: "\(configDir)/last-bad-signature.json", contents: d,
                                                       attributes: [.posixPermissions: 0o600])
                    }
                    continue
                }
                return .denied("phone")
            }
            return nil
        }
        g.addTask { try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1e9)); return .timeout }
        var result: Outcome = .timeout
        var pending = askOnMac ? 3 : 2
        while pending > 0, let r = await g.next() {
            pending -= 1
            if let r { result = r; break }
        }
        ctx.invalidate()
        g.cancelAll()
        return result
    }

    // Tell the phone to clear its prompt if the answer came from elsewhere.
    switch outcome {
    case .approved("phone"), .denied("phone"): break
    default: try? await publish(c.reqTopic, ["type": "cancel", "id": id], c)
    }

    switch outcome {
    case .approved(let via): log(cli, argsText, "approved", via, callerKind); return 0
    case .denied(let via):
        log(cli, argsText, "denied", via, callerKind)
        FileHandle.standardError.write("approve: declined on \(via)\n".data(using: .utf8)!)
        return 1
    case .timeout:
        log(cli, argsText, "timeout", "-", callerKind)
        FileHandle.standardError.write("approve: no answer within \(Int(timeoutSeconds))s\n".data(using: .utf8)!)
        return 2
    }
}
