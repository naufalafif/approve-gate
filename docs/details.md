# Approve Gate: details

The short version with diagrams is the [README](../README.md). This page covers the parts, the
protocol, what it does and does not protect against, every command, and the checks.

## Parts

| Part | Path | What it does |
|---|---|---|
| Mac program | `mac/*.swift` → `~/bin/approve` | One binary: the approval (Touch ID and the phone), the CLI wrapper, pairing, and the Claude Code hook |
| Wrapped CLIs | `~/.local/bin/touchid-wrap/<cli>` → `~/bin/approve` | Symlinks. Called as `vault`, `hcloud` and so on, `approve` checks the rules, asks if needed, then runs the real CLI (the next one on `PATH`) |
| Rules | `mac/rules.example.json` → `~/.config/approve-gate/rules.json` | Which calls are free per CLI, which targets count as production, and the hcloud contexts the hook protects |
| Claude Code hook | `approve hook` (PreToolUse, Bash) | Blocks destructive hcloud verbs on production contexts, direct Hetzner API calls and `HCLOUD_TOKEN=`; asks before package installs |
| Android app | `android/` (Kotlin, minSdk 30) | Listens for requests, shows them after unlock, signs approvals with a fingerprint-bound key |
| Fake phone | `tools/fakephone.swift` | Same protocol with a software key, for tests |

## How an approval is trusted

- **Pairing.** `approve pair` makes a random AES-256 key and two random relay topics and shows them
  in a QR code. The key is held in memory until the phone answers, so nothing on disk can be read and
  raced. The phone creates a P-256 key in the Android Keystore (StrongBox when available) that needs
  a fresh strong-biometric match for every signature and is invalidated when fingerprints change. It
  sends the public half, signed by that key, and the Mac saves it.
- **Changing the pairing.** `approve pair` and `approve unpair` only run in a real terminal, and when a
  phone is already paired they need an approval first. A script or agent cannot swap in a phone it
  controls by running them.
- **Requests.** Each request is encrypted with the shared key, so the relay (ntfy.sh by default) only
  sees ciphertext. Control and invisible characters in the command are shown as `\u{…}`, and a
  very long command says how many characters are not shown.
- **Approvals.** A phone approval is an ECDSA signature over the SHA-256 of the exact request bytes,
  which include a fresh id and expiry. The Mac accepts it only if it verifies against the paired
  public key, so a forged, replayed or edited approval is ignored.
- **Phone privacy.** Notifications show the CLI, target and caller, never the command, because
  Android can show notification text on the lock screen. The command shows after unlock. App data is
  excluded from backups. Pairing links open only from the in-app scanner or adb, not from web pages.
- **Failing closed.** A deny, a timeout (90 s by default) or an unreachable relay stops the command.

## Locking it down: system mode and the credential broker

A program running as you can do anything your account can. Two features take that away step by step:

1. **System mode** (`make system-install`, asks for sudo once). The binary goes to
   `/usr/local/libexec/approve-gate/approve` and the rules, pairing and isolated homes to
   `/Library/Application Support/ApproveGate/`, all owned by root. The root-owned binary only reads
   that folder, and ignores a file there that is not root-owned (every call then asks, and phone
   approvals stop). Changing rules (`approve rules …`) or the pairing asks Touch ID or the phone, with
   the change named in the prompt. A small root helper (`com.naufalafif.approve-gate.helper`, a
   LaunchDaemon that `approve setup` installs) then writes the file. It only accepts the root-owned
   approve binary as its caller, checked by its exact code hash with the hardened runtime on, so no
   other program can call it or inject code into approve to skip the approval. Without the helper (or
   when Touch ID is unavailable and no phone is paired), changes fall back to `sudo` or the macOS admin
   prompt.
2. **Credential broker.** Store a CLI's credential with `approve secret set NAME` and remove it from
   the CLI's own config file. In system mode the secret goes to a root-only folder
   (`/Library/Application Support/ApproveGate/secrets`, 0700, files 0600) that only the settings
   helper reads and writes, and only for the root-owned approve, checked by code hash on every
   request, so upgrades keep working with no prompt. A secret left in the Keychain by an older version
   moves there on first use (one Keychain password prompt) and is removed from the Keychain. In user
   mode, or without the helper, secrets stay in the login Keychain, where only that approve binary is
   trusted to read them. In the
   rules, give the CLI a fixed `path` and an `env` such as `{"VAULT_TOKEN": "secret:vault-token",
   "VAULT_ADDR": "https://vault.example.com"}`. approve then hands the secret to the real CLI only
   after the rules or your approval allow the call, with a clean environment and an isolated HOME, so
   neither `PATH`, environment variables nor files in your home can send it elsewhere. Flags that point
   a CLI at another server go in `gatedArgs`, so they always ask.

With both in place, calling the real CLI directly gets no credential, reading the Keychain item
shows a password prompt, changing the rules or the pairing needs your fingerprint, and changing the binary needs sudo.

## What it does not protect against

- **Credentials still in files.** Until a CLI's credential is moved into the broker and deleted from
  its config file (`~/.vault-token`, `cli.toml`, ...), anything running as you can use it directly.
  CLIs that keep session files (such as kcadm) cannot use the broker yet.
- **User mode.** A copy in `~/bin` with settings in `~/.config` can be changed by anything running as
  you. Use it for development.
- **Keychain item deletion (user mode).** Another program can delete a Keychain secret; the CLI then fails until
  you set it again. It cannot read it without your password.
- **The hook is a seatbelt.** It blocks direct calls to the real binaries, changes to Approve Gate's
  own files and Keychain items, and edits that remove the hook or turn hooks off, by matching the
  command text. A determined caller can phrase around it; system mode and the broker are the real
  protection.
- **What it shows.** Commands are logged in full and shown on the phone, including secrets passed as
  arguments. The production label comes from flags and environment, so it is a hint.
- **sudo fallback.** If Touch ID cannot run and no phone is paired, a call without broker secrets
  falls back to the `sudo` prompt; with passwordless sudo that passes. Broker CLIs never fall back.
- **Homebrew is yours.** `/opt/homebrew` belongs to your user, so anything running as you can replace
  binaries there, including the Homebrew copy of `approve` before you run `approve setup`. After
  setup, only the root-owned copy is trusted: the menu bar app runs it, and broker CLIs must be
  root-owned. A launcher that runs a user-owned program (such as a CLI in `~/.local`) inherits that
  program's exposure.
- **Who asks.** The prompt's "From" line comes from the caller's environment
  (`CLAUDE_CODE_SESSION_ID`) and "Why" from `APPROVE_REASON`; a caller can leave them out or word them
  as it likes. The command line and, for settings changes, the summary are what Approve Gate itself
  computed.
- **The pairing key.** In system mode the relay key in `config.json` is readable by your user, since
  every gated call needs it. A program running as you can read requests and send prompts to the
  phone, but cannot approve: approvals are signed by the phone's hardware key.
- **The log.** `~/.approve-gate.log` is yours, so it can be edited. It is a record, not evidence.
- **Your own relay.** The relay in `relay/` accepts any topic without limits. Deploy it on an account
  where that is acceptable, or add a rate limit.
- **Pairing.** Pairing or unpairing always asks first (Touch ID, or the phone when paired; typing it
  in a terminal when neither exists). `approve setup` never imports a pairing from your home folder:
  pair again after setup.

Also note:

- Commands are logged in full, and shown on the phone, including any secrets passed as arguments.
- If Touch ID cannot run and no phone is paired, `approve` falls back to the `sudo` prompt. With
  passwordless `sudo` configured, that fallback passes without asking.
- The production label comes from the command's flags and environment, so it is a hint, not a guarantee.

## Use

```
make install            # test, install ~/bin/approve, copy the example rules once, link the CLIs
make test               # rule and hook decisions against tests/*.tsv
make e2e                # full pair-and-approve run with the fake phone (temporary config)
make apk                # build the Android APK
approve pair            # show the pairing QR; scan it in the app (terminal only)
approve pair --png      # also save the QR as a PNG, deleted once paired
approve status          # pairing, rules file, and the real binary behind each wrapped CLI
approve unpair          # terminal only; needs an approval while a phone is paired
approve check hcloud server list                      # free or gated, runs nothing
approve request --cli vault -- kv put secret/x a=b    # exit 0 approved, 1 denied, 2 no answer, 3 Touch ID unavailable (unpaired)
approve link [DIR]      # (re)create the CLI symlinks, default ~/.local/bin/touchid-wrap; removes links of commands no longer gated
approve hook install    # turn the Claude Code hook on in ~/.claude/settings.json
```

Everything the Settings window changes also works from the command line, so you can ask an agent to
do it. Each change prints a diff; in system mode Touch ID or the phone asks, naming the change
("turn gating off for kubectl (rules kept)"), in user mode it needs a terminal:

```
approve rules show [CLI] [--json]          approve rules templates [--json]
approve rules add kubectl [--empty]        approve rules remove kubectl
approve rules disable kubectl              approve rules enable kubectl    # pause gating, keep the rules
approve rules ask kubectl always|reads
approve rules free kubectl add|rm 'rollout status*'      approve rules free kubectl reset
approve rules gated-arg kubectl add|rm '--context*'
approve rules timeout 60                   approve rules ask-on-mac on|off
approve rules production add|rm WORD...    approve rules relay https://relay.example|default
approve rules install FILE                 # several changes in one prompt
```

A command with gating off runs as the plain command: its link is removed, the hook stops guarding
it, and it never gets broker secrets.

A gated call that is denied or not answered stops with "not approved". If the real CLI is not on
`PATH` (absolute entries only) the call fails with 127.

Env: `APPROVE_REASON` (one line, shown as "reason given, not verified"), `APPROVE_TIMEOUT` (10-300 s),
`APPROVE_NO_MAC=1` (skip the Mac prompt; testing only, it can only remove an approval path).

Files: `~/.approve-gate.log` (one line per wrapped call: free, approved, denied or timeout, which
device, the caller), `~/.config/approve-gate/config.json` (pairing, 0600), `rules.json` (0600).

### Rules

Free patterns match the arguments word by word from the start. Each word of the pattern is a shell
glob for the argument in the same place, and only a last word ending in `*` lets more arguments
follow. So `"* list*"` matches `server list -o json` but not `server create --name list`, and
`"* --help"` matches `server --help` but not `server create --help` or `exec pod -- sh --help`.
An empty pattern `""` matches a call with no arguments. A word later in the command is never enough
to make a call free.

A command whose rules give it Keychain secrets must have a fixed `path`, and in system mode that
file and every folder above it must be root-owned and not writable by others (a Homebrew binary in
`/opt/homebrew` is yours, so it does not qualify: put a root-owned copy or launcher in
`/usr/local/libexec`).

## Tests

- `tests/run.sh`: 30 rule decisions, 54 hook decisions and 10 file-tool decisions.
- `tests/e2e.sh`: with a test build (`make test-build`, its own config folder, system mode simulated)
  and the fake phone over a local relay (`tests/relay.py`, so tests never hit ntfy.sh limits):
  the credential broker with a dummy Keychain secret, tampered rules, pairing (no key on disk while waiting, terminal required), free call, phone approve,
  deny, forged signature, no answer, hidden characters, long commands, and approval for re-pairing and
  unpairing, and every `approve rules` change (gating off and on, links, hook, diff, refusals). It never runs the installed binary or touches the real pairing, and fails if the shipped
  binary contains the test-only overrides.
- The Android app is tested by hand on an emulator with an enrolled fingerprint and on a physical phone.

## Your own relay on Cloudflare

ntfy.sh is a free public service with a per-network rate limit; when it is used up (HTTP 429), phone
approvals stop until it resets. `relay/` is a small Cloudflare Worker that speaks the part of the ntfy
protocol Approve Gate uses: one Durable Object per topic, messages kept 15 minutes, only Approve Gate
topic names, 16 KB per message. It only ever sees the encrypted messages.

```
cd relay && npm ci && cf deploy        # prints https://approve-gate-relay.<you>.workers.dev
approve pair --server https://approve-gate-relay.<you>.workers.dev
APPROVE_E2E_RELAY=https://approve-gate-relay.<you>.workers.dev tests/e2e.sh   # full test against it
```

## Releases and Obtainium

`make release` builds the signed APK on the Mac, checks it is signed with the release certificate,
and publishes it as a GitHub release tagged `v<versionName>` with the APK attached. Put the keystore
path in `local.mk` (`AG_KEYSTORE := /path/to/release.jks`, not committed) and its password in the macOS
Keychain (service `approve-gate-keystore`). Bump `versionCode` and `versionName` in
`android/app/build.gradle.kts` first; the script refuses to run on a dirty tree, off `main`, or before
`main` is pushed. Release builds are never made in CI, so the signing key stays on the Mac.

In Obtainium, add the repository URL as the source. Each update is signed with the same key, so the
pairing survives.

Release certificate SHA-256: `3a66ba332113d7beb1a39e7311c65aace379ff747b167f624e4eb0af51a40826`.

## Checks

Every push and pull request to `main` runs two workflows. Security also runs every Monday.

| Workflow | Check | Tool | Blocks on |
|---|---|---|---|
| CI | Mac build and smoke test | `swiftc` | build failure |
| CI | Rule and hook decisions | `tests/run.sh` | any decision that differs from `tests/*.tsv` |
| CI | End to end with the fake phone | `tests/e2e.sh` | any failed step |
| CI | Android lint and debug build | Gradle, Android lint | lint errors, build failure |
| Security | Secrets in the whole git history | gitleaks | any finding |
| Security | SAST for Kotlin, Java, Swift, workflows | Semgrep | any finding |
| Security | Known vulnerabilities in libraries that ship in the APK | OSV-Scanner on `gradle.lockfile` | any finding |
| Security | Same scan for build tooling | OSV-Scanner | report only, not shipped |
| Security | Workflow mistakes and injection risks | actionlint, zizmor | any finding |
| Security | Gradle wrapper jar is the official one | gradle/actions wrapper-validation | mismatch |

Dependabot opens weekly updates for Gradle libraries and pinned actions; actions are pinned to commit
hashes. Run the same scans locally with `make scan`, and install the commit hooks with
`pre-commit install`. After changing a dependency, refresh the lockfile:
`cd android && ./gradlew :app:dependencies --write-locks`.
