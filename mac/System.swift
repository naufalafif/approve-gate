// Where the settings live, and who may change them.
//
// User mode (a copy in ~/bin, for development): rules and pairing in ~/.config/approve-gate.
// System mode (the root-owned install from `make system-install`): rules, pairing and the isolated
// homes live in a root-owned folder, so a program running as you cannot loosen the rules, swap the
// phone, or replace approve. Changes go through `sudo`, whose prompt is your approval.

import CryptoKit
import Foundation

#if APPROVE_TEST
let systemDir = "\(configDir)/system"
let systemOwner: uid_t = getuid()
/// Test build: system mode on request, owned by the current user instead of root.
let systemMode = ProcessInfo.processInfo.environment["APPROVE_TEST_SYSTEM"] == "1"
#else
let systemDir = "/Library/Application Support/ApproveGate"
let systemOwner: uid_t = 0
/// The root-owned binary always uses the root-owned settings and never falls back to ~/.config.
let systemMode = isProtected(ownExecutable())
#endif

var settingsDir: String { systemMode ? systemDir : configDir }
var configPath: String { "\(settingsDir)/config.json" }

/// Owned by the system owner (root), and not writable by group or others; the same for its folder.
func isProtected(_ path: String) -> Bool {
    func ok(_ p: String) -> Bool {
        var st = stat()
        guard lstat(p, &st) == 0, (st.st_mode & S_IFMT) != S_IFLNK else { return false } // a link's target can change
        return st.st_uid == systemOwner && st.st_mode & 0o022 == 0
    }
    return ok(path) && ok((path as NSString).deletingLastPathComponent)
}

/// Reads a settings file. In system mode a file that is not root-owned counts as missing, so a
/// tampered file fails closed: every call asks, and phone approvals stop.
func readSettings(_ path: String) -> Data? {
    if systemMode, FileManager.default.fileExists(atPath: path), !isProtected(path) {
        FileHandle.standardError.write("approve: \(path) is not root-owned; ignoring it\n".data(using: .utf8)!)
        return nil
    }
    return FileManager.default.contents(atPath: path)
}

/// Set once a change was approved another way (re-pairing asks first), so it is not asked twice.
var settingsChangeApproved = false

/// Writes (or with nil, removes) a settings file. System mode: through the settings helper after
/// Approve Gate's own approval (Touch ID or phone), or, without the helper, `sudo approve _install`.
/// `reason` names the change in the prompt ("Approve Gate wants to …"), so you see what you allow.
let settingsReasonLimit = 400

func writeSettings(_ data: Data?, _ path: String, reason: String = "change its settings") throws {
    // The reason is all the approver sees of the change: never cut it, refuse instead.
    let reason = visible(reason)
    guard reason.count <= settingsReasonLimit else {
        throw NSError(domain: "approve", code: 1, userInfo: [NSLocalizedDescriptionKey:
            "this change is too long to show in one approval (\(reason.count) characters, at most \(settingsReasonLimit)); make it in smaller steps"])
    }
    if !systemMode {
        try FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        if let data {
            guard FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                throw NSError(domain: "approve", code: 1, userInfo: [NSLocalizedDescriptionKey: "could not write \(path)"])
            }
        } else { try? FileManager.default.removeItem(atPath: path) }
        return
    }
    if helperAvailable {
        let code = settingsChangeApproved ? 0 : approveSettingsChange(reason)
        switch code {
        case 0: try helperWrite(data, path); return
        case 1: throw NSError(domain: "approve", code: 1, userInfo: [NSLocalizedDescriptionKey: "declined"])
        case 2: throw NSError(domain: "approve", code: 1, userInfo: [NSLocalizedDescriptionKey: "no answer"])
        default: break // Touch ID unavailable and no phone: the admin prompt below asks instead
        }
    }
    var src = "-"
    if let data {
        src = NSTemporaryDirectory() + "approve-" + UUID().uuidString
        FileManager.default.createFile(atPath: src, contents: data, attributes: [.posixPermissions: 0o600])
    }
    defer { if src != "-" { try? FileManager.default.removeItem(atPath: src) } }
    // The temp file sits in your folder while the admin prompt is open, so a program could swap it.
    // Root writes it only if its hash still matches what was approved here.
    let digest = data.map(sha256Hex) ?? "-"
    let p = Process()
    #if APPROVE_TEST
    p.executableURL = URL(fileURLWithPath: ownExecutable())
    p.arguments = ["_install", src, path, digest]
    #else
    if isatty(0) == 1 {
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-p", "approve: your password (or Touch ID) to let Approve Gate \(reason.replacingOccurrences(of: "%", with: "%%")): ",
                       ownExecutable(), "_install", src, path, digest]
    } else {
        // No terminal (the menu bar app): the macOS admin prompt asks instead of sudo.
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let shell = [ownExecutable(), "_install", src, path, digest].map(q).joined(separator: " ")
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        let script = "do shell script \"\(esc(shell))\" "
            + "with prompt \"Approve Gate wants to \(esc(reason)).\" with administrator privileges"
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
    }
    #endif
    try p.run()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else {
        throw NSError(domain: "approve", code: 1, userInfo: [NSLocalizedDescriptionKey: "settings not changed"])
    }
}

func sha256Hex(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

/// `approve _install SRC|- DEST SHA256|-`, run as root by writeSettings. Only the two settings files, and only
/// content that parses as that file, can be written.
func runInstall(_ argv: [String]) -> Never {
    guard argv.count == 3 else { die("_install SRC|- DEST SHA256|-") }
    let (src, dest, digest) = (argv[0], argv[1], argv[2])
    #if !APPROVE_TEST
    guard geteuid() == 0 else { die("_install must run as root") }
    #endif
    let rules = "\(systemDir)/rules.json", config = "\(systemDir)/config.json"
    guard dest == rules || dest == config else { die("_install only writes \(rules) or \(config)") }
    if src == "-" {
        do { try installSettingsFile(nil, dest) } catch { die(error.localizedDescription) }
        exit(0)
    }
    guard let data = readRegularFile(src) else { die("cannot read \(src)") }
    guard sha256Hex(data) == digest else { die("\(src) changed after it was approved; nothing written") }
    do { try installSettingsFile(data, dest) } catch { die(error.localizedDescription) }
    exit(0)
}

/// Replaces (or with nil, removes) one of the two root-owned settings files. Only those two files,
/// and only content that parses as that file. Used by `_install` and the settings helper.
func installSettingsFile(_ data: Data?, _ dest: String) throws {
    func fail(_ m: String) -> NSError { NSError(domain: "approve", code: 1, userInfo: [NSLocalizedDescriptionKey: m]) }
    let rules = "\(systemDir)/rules.json", config = "\(systemDir)/config.json"
    guard dest == rules || dest == config else { throw fail("only \(rules) or \(config) can be written") }
    guard let data else {
        guard dest == config else { throw fail("only the pairing can be removed") }
        try? FileManager.default.removeItem(atPath: dest)
        return
    }
    let newRules = dest == rules ? try? JSONDecoder().decode(Rules.self, from: data) : nil
    let parses = dest == rules ? newRules != nil : (try? JSONDecoder().decode(Config.self, from: data)) != nil
    guard parses else { throw fail("not a valid \((dest as NSString).lastPathComponent)") }
    let tmp = dest + ".new"
    try? FileManager.default.removeItem(atPath: tmp)
    // Rules readable by all; the pairing (relay key) readable by the owner's group (staff) only.
    let mode: Int = dest == rules ? 0o644 : 0o640
    guard FileManager.default.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: mode]) else {
        throw fail("cannot write \(tmp)")
    }
    #if !APPROVE_TEST
    chown(tmp, 0, dest == rules ? 0 : 20) // root:wheel, or root:staff for the pairing
    #endif
    guard rename(tmp, dest) == 0 else { throw fail("cannot replace \(dest)") }
    // A command added here may get broker secrets: give it its isolated home now, not at the next setup.
    if let newRules { createIsolatedHomes(newRules) }
}
