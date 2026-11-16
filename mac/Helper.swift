// The settings helper: a small root daemon (installed by `approve setup`) that writes the two
// root-owned settings files, so changing a setting asks Approve Gate's own Touch ID or phone prompt,
// which names the change, instead of the macOS admin password dialog.
//
// Who may ask: only the root-owned approve binary, checked per connection by its exact code hash
// (cdhash) and hardened runtime, so no other program can inject code into it or impersonate it.
// That binary asks for approval before it sends a change, so a program running as you, such as an
// agent, cannot change the rules without your fingerprint. The helper still accepts only content
// that parses as the target file, exactly like `_install`.

import Foundation
import Security

#if APPROVE_TEST
var helperSocket: String { "\(configDir)/helper.sock" }
#else
let helperSocket = "/var/run/approve-gate.sock"
#endif
let helperLabel = "com.naufalafif.approve-gate.helper"
let helperPlist = "/Library/LaunchDaemons/\(helperLabel).plist"

/// True when a change can go through the helper (it is installed and listening).
var helperAvailable: Bool {
    var st = stat()
    return lstat(helperSocket, &st) == 0 && (st.st_mode & S_IFMT) == S_IFSOCK
}

// MARK: - Client

/// One request to the helper. Returns what follows "ok" in its reply; throws with its reason otherwise.
private func helperCall(_ msg: [String: Any]) throws -> String {
    func fail(_ m: String) -> NSError { NSError(domain: "approve", code: 1, userInfo: [NSLocalizedDescriptionKey: m]) }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw fail("cannot open a socket") }
    defer { close(fd) }
    var tv = timeval(tv_sec: 15, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    guard connectUnix(fd, helperSocket) else { throw fail("the settings helper is not running; run `approve setup`") }
    let body = try JSONSerialization.data(withJSONObject: msg)
    guard writeAll(fd, body) else { throw fail("could not send the request to the settings helper") }
    shutdown(fd, SHUT_WR)
    let reply = String(data: readAll(fd, limit: 1 << 20), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard reply == "ok" || reply.hasPrefix("ok ") else { throw fail(reply.isEmpty ? "the settings helper did not answer" : reply) }
    return String(reply.dropFirst(3))
}

/// Sends one settings change to the helper. Throws with the helper's reason when it refuses.
func helperWrite(_ data: Data?, _ dest: String) throws {
    var msg: [String: Any] = ["dest": dest]
    if let data { msg["data"] = data.base64EncodedString() }
    _ = try helperCall(msg)
}

/// A request to the helper's secret store (secret-get returns the value in base64, secret-list the names).
func helperSecret(_ msg: [String: Any]) throws -> String { try helperCall(msg) }

/// Asks for approval of a settings change (Touch ID or the phone), naming the change.
/// Returns request()'s exit code: 0 approved, 1 denied, 2 no answer, 3 Touch ID unavailable.
func approveSettingsChange(_ what: String) -> Int32 {
    let sema = DispatchSemaphore(value: 0)
    var code: Int32 = 2
    Task.detached {
        code = await request(cli: "approve", args: Array(CommandLine.arguments.dropFirst()), summary: what)
        sema.signal()
    }
    sema.wait()
    return code
}

// MARK: - Server

/// `approve _helper`: run by launchd as root. Serves one change at a time.
func runHelper() -> Never {
    guard runningAsRoot else { die("_helper runs as root from launchd (approve setup installs it)") }
    unlink(helperSocket)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0, bindUnix(fd, helperSocket) else { die("cannot listen on \(helperSocket)", 1) }
    chmod(helperSocket, 0o666) // anyone may connect; the caller check below decides
    guard listen(fd, 8) == 0 else { die("cannot listen on \(helperSocket)", 1) }
    signal(SIGPIPE, SIG_IGN)
    while true {
        let c = accept(fd, nil, nil)
        guard c >= 0 else { continue }
        var tv = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let reply = serve(c)
        _ = writeAll(c, Data((reply + "\n").utf8))
        close(c)
    }
}

private func serve(_ c: Int32) -> String {
    if let why = refuseCaller(c) {
        helperLog("refused: \(why)")
        return "error: refused: \(why)"
    }
    let body = readAll(c, limit: 4 << 20)
    guard let msg = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return "error: bad request" }
    if let op = msg["op"] as? String { return serveSecret(op, msg) }
    guard let dest = msg["dest"] as? String else { return "error: bad request" }
    var data: Data?
    if let b64 = msg["data"] as? String {
        guard let d = Data(base64Encoded: b64) else { return "error: bad request" }
        data = d
    }
    do {
        try installSettingsFile(data, dest)
        helperLog("wrote \(dest)")
        return "ok"
    } catch {
        return "error: \(error.localizedDescription)"
    }
}

/// The root-only secret store: one 0600 file per name in a 0700 folder, never readable by your user.
var secretsDir: String { "\(systemDir)/secrets" }

private func serveSecret(_ op: String, _ msg: [String: Any]) -> String {
    let fm = FileManager.default
    rootDir(systemDir)
    if !fm.fileExists(atPath: secretsDir) { mkdir(secretsDir, 0o700) }
    chown(secretsDir, systemOwner, systemOwner == 0 ? 0 : getgid())
    chmod(secretsDir, 0o700)
    if op == "secret-list" {
        let names = ((try? fm.contentsOfDirectory(atPath: secretsDir)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        return "ok " + names.joined(separator: "\n")
    }
    guard let name = msg["name"] as? String, name.range(of: "^[A-Za-z0-9_][A-Za-z0-9_.-]*$", options: .regularExpression) != nil else {
        return "error: bad secret name"
    }
    let path = "\(secretsDir)/\(name)"
    switch op {
    case "secret-get":
        guard let d = readRegularFile(path) else { return "error: not found" }
        return "ok " + d.base64EncodedString()
    case "secret-set":
        guard let b64 = msg["data"] as? String, let d = Data(base64Encoded: b64), !d.isEmpty else { return "error: bad request" }
        let tmp = path + ".new"
        unlink(tmp)
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return "error: cannot write the secret" }
        let ok = d.withUnsafeBytes { write(fd, $0.baseAddress, d.count) } == d.count
        close(fd)
        guard ok, rename(tmp, path) == 0 else { unlink(tmp); return "error: cannot write the secret" }
        helperLog("stored secret \(name)")
        return "ok"
    case "secret-rm":
        guard unlink(path) == 0 else { return "error: not found" }
        helperLog("removed secret \(name)")
        return "ok"
    default:
        return "error: bad request"
    }
}

/// nil when the peer is the root-owned approve binary, else why it is refused.
func refuseCaller(_ c: Int32) -> String? {
    var token = audit_token_t()
    var len = socklen_t(MemoryLayout<audit_token_t>.size)
    guard getsockopt(c, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &len) == 0 else { return "no caller identity" }
    guard isProtected(systemBinary) else { return "\(systemBinary) is not root-owned" }
    guard let expected = signingInfo(systemBinary) else { return "\(systemBinary) is not signed" }
    guard expected.runtime else { return "\(systemBinary) is not signed with the hardened runtime" }
    let tokenData = withUnsafeBytes(of: &token) { Data($0) }
    var code: SecCode?
    guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: tokenData] as CFDictionary, [], &code) == errSecSuccess,
          let code else { return "caller code not found" }
    var req: SecRequirement?
    let hex = expected.cdhash.map { String(format: "%02x", $0) }.joined()
    guard SecRequirementCreateWithString("cdhash H\"\(hex)\"" as CFString, [], &req) == errSecSuccess, let req else {
        return "cannot build the code requirement"
    }
    guard SecCodeCheckValidity(code, [], req) == errSecSuccess else {
        var path: CFURL?
        var staticCode: SecStaticCode?
        if SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode {
            SecCodeCopyPath(staticCode, [], &path)
        }
        return "caller is not \(systemBinary) (\((path as URL?)?.path ?? "unknown program"))"
    }
    return nil
}

struct SigningInfo { let cdhash: Data; let runtime: Bool }

func signingInfo(_ path: String) -> SigningInfo? {
    var sc: SecStaticCode?
    guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &sc) == errSecSuccess, let sc,
          SecStaticCodeCheckValidity(sc, [], nil) == errSecSuccess else { return nil }
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(sc, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
          let d = info as? [String: Any], let cdhash = d[kSecCodeInfoUnique as String] as? Data else { return nil }
    let flags = (d[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
    return SigningInfo(cdhash: cdhash, runtime: flags & SecCodeSignatureFlags.runtime.rawValue != 0)
}

private func helperLog(_ s: String) {
    FileHandle.standardError.write("\(ISO8601DateFormatter().string(from: Date())) \(s)\n".data(using: .utf8)!)
}

// MARK: - launchd

/// Run by `_setup-root`: install the helper as a LaunchDaemon and (re)start it on the new binary.
func installHelperDaemon() throws {
    #if !APPROVE_TEST
    let plist: [String: Any] = [
        "Label": helperLabel,
        "ProgramArguments": [systemBinary, "_helper"],
        "RunAtLoad": true,
        "KeepAlive": true,
        "StandardErrorPath": "/Library/Logs/approve-gate-helper.log",
    ]
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    let tmp = helperPlist + ".new"
    try? FileManager.default.removeItem(atPath: tmp)
    guard FileManager.default.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: 0o644]) else {
        throw NSError(domain: "approve", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot write \(helperPlist)"])
    }
    chown(tmp, 0, 0)
    guard rename(tmp, helperPlist) == 0 else {
        throw NSError(domain: "approve", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot replace \(helperPlist)"])
    }
    for args in [["bootout", "system/\(helperLabel)"], ["bootstrap", "system", helperPlist]] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        if args[0] == "bootstrap", p.terminationStatus != 0 {
            throw NSError(domain: "approve", code: 1, userInfo: [NSLocalizedDescriptionKey: "launchctl bootstrap failed (\(p.terminationStatus))"])
        }
    }
    #endif
}

// MARK: - Socket plumbing

private func withUnixAddr<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T? {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
        for (i, b) in bytes.enumerated() { buf[i] = b }
        buf[bytes.count] = 0
    }
    return withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
}

private func connectUnix(_ fd: Int32, _ path: String) -> Bool { withUnixAddr(path) { connect(fd, $0, $1) == 0 } ?? false }
private func bindUnix(_ fd: Int32, _ path: String) -> Bool { withUnixAddr(path) { bind(fd, $0, $1) == 0 } ?? false }

private func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { buf in
        var off = 0
        while off < buf.count {
            let n = write(fd, buf.baseAddress! + off, buf.count - off)
            if n <= 0 { return false }
            off += n
        }
        return true
    }
}

private func readAll(_ fd: Int32, limit: Int) -> Data {
    var out = Data()
    var buf = [UInt8](repeating: 0, count: 65536)
    while out.count < limit {
        let n = read(fd, &buf, buf.count)
        if n <= 0 { break }
        out.append(contentsOf: buf[0..<n])
    }
    return out
}
