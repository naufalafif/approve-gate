// approve: one program for the whole Mac side of Approve Gate.
//
//   approve pair [--server URL] [--png] [--link]   pair a phone (QR code; terminal only)
//   approve request --cli NAME -- ARGS   ask for approval; exit 0 approved, 1 denied, 2 timeout,
//                                        3 Touch ID unavailable and no phone paired
//   approve status                       show pairing state and where the rules live
//   approve unpair                       forget the phone (terminal only, needs approval)
//   approve check CLI [ARGS...]          print free or gated for a call, run nothing
//   approve hook                         Claude Code PreToolUse hook for Bash (reads JSON on stdin)
//   approve link [DIR]                   link the wrapped CLIs in DIR to this program
//   approve secret set NAME | rm NAME | list   Keychain secrets for the credential broker
//   approve rules show|add|remove|disable|enable|ask|free|gated-arg|timeout|ask-on-mac|production|relay|install
//                                        read or change the rules (`approve rules help`); changes go
//                                        through the admin prompt in system mode, a terminal in user mode
//   approve hook install                 turn the Claude Code hook on in ~/.claude/settings.json
//   approve setup                        root-owned install or update (after brew install/upgrade)
//   approve --version
//
// Linked under another name (vault, hcloud, doctl, kcadm, rd, stripe) it is that CLI's gate:
// free calls run straight away, anything else needs Touch ID or the phone first.

import Foundation

forwardToSystemCopyIfInstalled()

let invokedAs = URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent
if !invokedAs.hasPrefix("approve") {
    await runWrapped(invokedAs, Array(CommandLine.arguments.dropFirst()))
}

var argv = Array(CommandLine.arguments.dropFirst())
let cmd = argv.isEmpty ? "help" : argv.removeFirst()
switch cmd {
case "pair":
    await pair(server: flagValue(argv, "--server") ?? loadRules()?.relay?.server ?? "https://ntfy.sh",
               png: argv.contains("--png"), showLink: argv.contains("--link"))
case "request":
    guard let cli = flagValue(argv, "--cli") else { die("request needs --cli NAME -- ARGS") }
    let rest = argv.firstIndex(of: "--").map { Array(argv[($0 + 1)...]) } ?? []
    exit(await request(cli: cli, args: rest))
case "status":
    if argv.contains("--json") {
        FileHandle.standardOutput.write(await statusJSON())
        print("")
        exit(0)
    }
    print(systemMode ? "Mode: system (root-owned settings in \(systemDir))" : "Mode: user (settings in \(configDir))")
    if let c = loadConfig(), c.phonePublicKey != nil {
        print("Paired with \(c.phoneName ?? "phone") since \(c.pairedAt ?? "?") via \(c.server)")
    } else { print("Not paired: Touch ID only. Run `approve pair`.") }
    if systemMode {
        print(helperAvailable ? "Settings changes: Touch ID or the phone (settings helper running)"
                              : "Settings changes: macOS admin prompt (settings helper not running; run `approve setup`)")
    }
    if let r = loadRules() {
        print("Rules: \(rulesPath) (\(r.clis.keys.sorted().joined(separator: ", ")))")
    } else { print("Rules: \(rulesPath) missing or unreadable, so every wrapped call asks") }
    if let r = loadRules() {
        let stored = Set(secretNames())
        for name in r.clis.keys.sorted() {
            let rule = r.clis[name]
            let real = rule?.path ?? findReal(name) ?? "real binary not found"
            let secrets = (rule?.env ?? [:]).values.filter { $0.hasPrefix("secret:") }.map { String($0.dropFirst(7)) }
            let note = secrets.isEmpty ? "" : "  secrets: " + secrets.sorted().map { stored.contains($0) ? $0 : "\($0) (NOT SET)" }.joined(separator: ", ")
            print("  \(name): \(real)\(note)\(rule?.disabled == true ? "  (off: runs without asking)" : "")")
        }
    }
case "unpair":
    await guardPairingChange("unpair")
    do { try writeSettings(nil, configPath) } catch { die("pairing not removed: \(error.localizedDescription)", 1) }
    print("Unpaired. Gated commands use Touch ID only.")
case "check":
    // `--rules PATH` is for tests; check never runs anything.
    var rest = argv
    var rules = loadRules()
    if rest.first == "--rules", rest.count >= 2 { rules = loadRules(rest[1]); rest.removeFirst(2) }
    guard let cli = rest.first else { die("check needs CLI [ARGS...]") }
    print(rules?.clis[cli]?.disabled == true ? "free (gating is off)" : gateDecision(cli: cli, args: Array(rest.dropFirst()), rules: rules))
case "hook":
    if argv.first == "install" { runHookInstall() }
    runHook(argv)
case "link":
    guard let rules = loadRules() else { die("no rules at \(rulesPath); copy mac/rules.example.json there first") }
    linkCLIs(argv.first ?? defaultLinkDir, rules)
case "secret":
    await runSecret(argv)
case "rules":
    runRules(argv)
case "_install":
    runInstall(argv)
case "_helper":
    runHelper()
case "setup":
    runSetup()
case "_setup-root":
    runSetupRoot(argv)
case "--version", "version":
    print("approve \(approveVersion)")
default:
    print("usage: approve pair [--server URL] [--png] [--link] | request --cli NAME -- ARGS | status | unpair | check CLI [ARGS] | hook [install] | link [DIR] | secret set|rm|list | rules help | setup | --version")
}
