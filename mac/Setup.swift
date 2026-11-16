// `approve setup`: the root-owned install (system mode), from wherever this copy came from
// (Homebrew, or a build in the repo). Run it after installing and after every upgrade.
//
// As you:  asks for sudo once, then points ~/bin/approve at the root-owned binary, links the CLIs,
//          and installs the menu bar app if this copy ships one.
// As root (`_setup-root`): copies this binary and the rules (yours, or the example; never a pairing)
//          into the root-owned locations, and creates the isolated homes.

import Foundation

let approveVersion = "0.7.2"
#if APPROVE_TEST
// Test build: the "root-owned" install goes into the test folder, owned by you (tests/e2e.sh).
let systemBinary = "\(configDir)/libexec/approve-gate/approve"
let runningAsRoot = true
#else
let systemBinary = "/usr/local/libexec/approve-gate/approve"
let runningAsRoot = geteuid() == 0
#endif

/// Files that ship next to this binary: Homebrew puts them in ../share/approve-gate, the repo in mac/.
func shipped(_ name: String) -> String? {
    let dir = (ownExecutable() as NSString).deletingLastPathComponent
    return ["\(dir)/../share/approve-gate/\(name)", "\(dir)/\(name)"]
        .map { ($0 as NSString).standardizingPath }
        .first { FileManager.default.fileExists(atPath: $0) }
}

/// Reads a regular file without following a symlink, so root never copies (or later chowns) a file
/// that a link in a user folder points at.
func readRegularFile(_ path: String) -> Data? {
    let fd = open(path, O_RDONLY | O_NOFOLLOW)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var st = stat()
    guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
    return FileHandle(fileDescriptor: fd, closeOnDealloc: false).readDataToEndOfFile()
}

private func rootInstall(_ src: String, _ dest: String, mode: Int, group: gid_t = 0) throws {
    func fail(_ m: String) -> NSError { NSError(domain: "approve", code: 1, userInfo: [NSLocalizedDescriptionKey: m]) }
    guard let data = readRegularFile(src) else { throw fail("\(src) is not a regular file") }
    // dest's folder is root-owned, so nobody else can place anything at tmp.
    let tmp = dest + ".new"
    unlink(tmp)
    let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(mode))
    guard fd >= 0 else { throw fail("cannot write \(tmp)") }
    let written = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) } == data.count
    fchown(fd, systemOwner, systemOwner == 0 ? group : getgid()) // test build: stays yours
    fchmod(fd, mode_t(mode))
    close(fd)
    guard written, rename(tmp, dest) == 0 else { unlink(tmp); throw fail("cannot replace \(dest)") }
}

func rootDir(_ path: String) {
    try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    chown(path, systemOwner, systemOwner == 0 ? 0 : getgid())
    chmod(path, 0o755)
}

/// The root-owned HOME each gated command gets when it receives broker secrets. Names that are not a
/// plain file name are skipped, so a rule cannot make root create folders anywhere else.
func createIsolatedHomes(_ r: Rules) {
    rootDir("\(systemDir)/home")
    for cli in r.clis.keys where cli.range(of: "^[A-Za-z0-9_][A-Za-z0-9._-]*$", options: .regularExpression) != nil {
        rootDir("\(systemDir)/home/\(cli)")
    }
}

/// `approve _setup-root USER_HOME EXAMPLE_RULES|-`, run as root by `approve setup`.
func runSetupRoot(_ argv: [String]) -> Never {
    guard runningAsRoot, argv.count == 2 else { die("_setup-root runs as root from approve setup") }
    let (userHome, example) = (argv[0], argv[1])
    let userCfg = "\(userHome)/.config/approve-gate"
    let fm = FileManager.default
    do {
        rootDir((systemBinary as NSString).deletingLastPathComponent)
        rootDir(systemDir)
        rootDir("\(systemDir)/home")
        try rootInstall(ownExecutable(), systemBinary, mode: 0o755)
        let rules = "\(systemDir)/rules.json"
        if !fm.fileExists(atPath: rules) {
            let src = fm.fileExists(atPath: "\(userCfg)/rules.json") ? "\(userCfg)/rules.json" : example
            guard src != "-", fm.fileExists(atPath: src) else { die("no rules to install: none in \(userCfg) and no example") }
            try rootInstall(src, rules, mode: 0o644)
        }
        // A pairing in your home folder is never imported: any program running as you can write
        // it, and importing it would let that program approve its own commands. Pair again instead.
        if fm.fileExists(atPath: "\(userCfg)/config.json"), !fm.fileExists(atPath: "\(systemDir)/config.json") {
            print("Not paired yet in system mode. Pair your phone again: approve pair")
        }
        if let d = fm.contents(atPath: rules), let r = try? JSONDecoder().decode(Rules.self, from: d) {
            createIsolatedHomes(r)
        }
        // Settings changes then ask Touch ID or the phone instead of the admin password dialog.
        if signingInfo(systemBinary)?.runtime == true {
            try installHelperDaemon()
        } else {
            print("Settings helper not installed: this build is not signed with the hardened runtime, so settings changes keep using the admin prompt.")
        }
    } catch {
        die("setup failed: \(error.localizedDescription)", 1)
    }
    exit(0)
}

func runSetup() -> Never {
    guard isatty(0) == 1 else { die("run `approve setup` yourself in a terminal", 1) }
    // `approve setup` after `brew upgrade` reaches the root-owned copy through ~/bin/approve. Install
    // the newer Homebrew copy instead of reinstalling this one.
    #if !APPROVE_TEST
    if systemMode {
        let mine = FileManager.default.contents(atPath: ownExecutable())
        for cand in ["/opt/homebrew/bin/approve", "/usr/local/bin/approve"] {
            guard FileManager.default.isExecutableFile(atPath: cand), let real = realPath(cand), real != ownExecutable(),
                  FileManager.default.contents(atPath: real) != mine else { continue }
            print("Installing the Homebrew copy (\(real)).")
            var cargs: [UnsafeMutablePointer<CChar>?] = [strdup(cand), strdup("setup"), nil]
            execv(cand, &cargs)
        }
    }
    #endif
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
    p.arguments = ["-p", "approve setup: your password (or Touch ID) to install Approve Gate root-owned: ",
                   ownExecutable(), "_setup-root", home, shipped("rules.example.json") ?? "-"]
    guard (try? p.run()) != nil else { die("could not run sudo") }
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { die("setup did not finish; nothing else changed", 1) }

    let fm = FileManager.default
    // One approve for everything: the command on PATH reaches the root-owned binary.
    let userBin = "\(home)/bin/approve"
    if fm.fileExists(atPath: "\(home)/bin") {
        try? fm.removeItem(atPath: userBin)
        try? fm.createSymbolicLink(atPath: userBin, withDestinationPath: systemBinary)
    }
    for args in [["link"], ["status"]] {
        let q = Process()
        q.executableURL = URL(fileURLWithPath: systemBinary)
        q.arguments = args
        try? q.run()
        q.waitUntilExit()
    }
    if let app = shipped("Approve Gate Status.app") {
        let dest = "/Applications/Approve Gate Status.app"
        _ = run(["/usr/bin/killall", "ApproveGateBar"])
        try? fm.removeItem(atPath: dest)
        if (try? fm.copyItem(atPath: app, toPath: dest)) != nil {
            _ = run(["/usr/bin/open", dest])
            print("Menu bar app installed: \(dest)")
        }
    }
    print("Approve Gate \(approveVersion) is set up.")
    exit(0)
}

private func run(_ argv: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: argv[0])
    p.arguments = Array(argv.dropFirst())
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return -1 }
    p.waitUntilExit()
    return p.terminationStatus
}

/// A copy that is not the root-owned one (Homebrew, ~/bin, the repo) hands every command to the
/// root-owned binary once it exists, so there is one approve in charge and one set of settings.
/// It warns when the root-owned copy is a different build: run `approve setup` to update it.
func forwardToSystemCopyIfInstalled() {
    #if !APPROVE_TEST
    let first = CommandLine.arguments.dropFirst().first ?? ""
    // APPROVE_NO_FORWARD=1 keeps a build in the repo on its own (tests, `make build`). Skipping the
    // forward is not a way around anything: this copy is user-owned and reads your home settings.
    guard !systemMode, isProtected(systemBinary), ProcessInfo.processInfo.environment["APPROVE_NO_FORWARD"] != "1",
          !["setup", "_setup-root", "--version", "version"].contains(first) else { return }
    let mine = FileManager.default.contents(atPath: ownExecutable())
    if mine != FileManager.default.contents(atPath: systemBinary) {
        setenv("APPROVE_ROOT_COPY_OUTDATED", "1", 1)
        FileHandle.standardError.write("approve: the root-owned copy is a different build; run `approve setup` to update it\n".data(using: .utf8)!)
    }
    var cargs: [UnsafeMutablePointer<CChar>?] = CommandLine.arguments.map { strdup($0) }
    cargs.append(nil)
    execv(systemBinary, &cargs)
    #endif
}
