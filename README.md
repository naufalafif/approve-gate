<p align="center"><img src="docs/logo.svg" width="112" alt="Approve Gate logo: a white fingerprint on purple"></p>

<h1 align="center">Approve Gate</h1>

**Your fingerprint, on every risky command.** Touch ID on your Mac, or the fingerprint sensor on
your Android phone, whichever is closer. Every prompt shows exactly what you are approving.

```
$ vault kv put secret/payments key=…
  → 🔒 Approve on Mac or phone?   vault kv put secret/payments …   Target: PRODUCTION
  ✓ Approved on phone
```

---

## 1. The problem

AI coding agents (and scripts, and tired humans) run commands on your machine. Most are harmless.
A few can delete a server, rotate a secret, or charge a card.

```mermaid
flowchart LR
    A["🤖 AI agent<br/>or a script"] -->|"hcloud server delete web-1"| C["☁️ Production"]
    style C fill:#fde8e8,stroke:#c62828
```

The usual fixes don't fit:

| Fix | Why it falls short |
|---|---|
| Ask "Allow?" in chat | You click yes 800 times a day and stop reading |
| `sudo` password prompt | Doesn't say what you're approving; useless when you're away from the keyboard |
| Block everything | The agent can't do its job |

## 2. The idea

Let the safe calls through. Stop the risky ones and ask **you**, with your fingerprint, showing the
**exact command and where it runs**. Answer from the Mac, or from your phone when you're away.

```mermaid
flowchart LR
    A["🤖 Command"] --> G{"Approve Gate"}
    G -->|"read-only<br/>(list, get, describe)"| R["✅ Runs"]
    G -->|"changes something"| F["👆 Your fingerprint<br/>Mac or phone"]
    F -->|"approve"| R
    F -->|"deny / no answer"| X["⛔ Stopped"]
    style R fill:#e8f5e9,stroke:#2e7d32
    style X fill:#fde8e8,stroke:#c62828
```

## 3. How it works

One small program on the Mac (`approve`), one app on the phone, and a relay in between that only
ever sees encrypted messages.

```mermaid
flowchart LR
    subgraph MAC["💻 Mac"]
        CMD["vault / hcloud / doctl<br/>kcadm / rd / stripe"]
        AP["approve<br/>one binary"]
        TID["Touch ID"]
        REAL["real CLI"]
    end
    subgraph RELAY["📨 ntfy.sh relay"]
        T["encrypted<br/>messages only"]
    end
    subgraph PHONE["📱 Android"]
        APP["Approve Gate app"]
        KEY["🔐 key in secure hardware<br/>unlocks with fingerprint"]
    end
    CMD --> AP
    AP --> TID
    AP <-->|"AES-256"| T
    T <--> APP
    APP --> KEY
    AP -->|"approved"| REAL
```

The CLI names are just links to `approve`. When you type `vault …`, `approve` decides whether to
ask, asks, and only then runs the real `vault`.

### One approval, step by step

```mermaid
sequenceDiagram
    participant You as 🤖 Agent / you
    participant A as approve (Mac)
    participant M as Touch ID
    participant P as 📱 Phone
    You->>A: vault kv put secret/x …
    par ask both at once
        A->>M: "run vault kv put … Target: prod"
    and
        A->>P: same details, encrypted
    end
    P->>P: 👆 fingerprint signs this exact request
    P->>A: signed "approve"
    A->>A: check signature
    A->>M: cancel the other prompt
    A->>You: ✅ runs the real vault
```

First answer wins. Deny, or no answer within 90 seconds, and the command doesn't run.

## 4. Why you can trust it

```mermaid
flowchart LR
    R["📨 Relay"] -.->|"sees only<br/>ciphertext"| X1["❌ can't read commands"]
    S["🕵️ Someone with the topic names"] -.-> X2["❌ can't fake a yes"]
    P["📱 Your phone + your finger"] --> OK["✅ the only way to approve remotely"]
```

- **Encrypted end to end.** The key travels once, inside the pairing QR code, never through the relay.
- **Signed by hardware.** The phone's signing key lives in its secure chip and needs a fresh
  fingerprint for every signature. A new fingerprint enrolled on the phone invalidates it.
- **One signature, one request.** Each approval covers one request id and expiry, so it can't be replayed.
- **No hidden tricks.** Invisible characters in a command show up as `\u{…}`, and a very long command
  says how much is cut off.
- **Pairing is yours.** A new pairing only starts from your terminal, and replacing a paired phone
  needs your approval first.
- **Nothing on the lock screen.** The notification shows the tool and target; the command appears after unlock.
- **Fails closed.** Relay down, phone off, no answer: the command does not run. Touch ID still works.

### What it isn't

Out of the box it's a checkpoint: it stops mistakes and keeps a well-behaved agent honest, with every
call logged. To make it a lock, use **system mode** (rules, pairing and binary owned by root) and the
**credential broker** (secrets in the Keychain, handed to the CLI only after approval).
[How, and what's left](docs/details.md#locking-it-down-system-mode-and-the-credential-broker).

## 5. Bonus: a seatbelt for Claude Code

`approve hook` plugs into Claude Code as a pre-command check. It blocks a short list of commands
outright (for example deleting servers on a production cloud account) so they never even reach the
approval step, and asks before package installs.

```mermaid
flowchart LR
    C["Claude Code<br/>wants to run a command"] --> H{"approve hook"}
    H -->|"destructive on prod"| B["⛔ blocked"]
    H -->|"package install"| Q["❓ asks you"]
    H -->|"everything else"| G["→ Approve Gate as usual"]
```

## 6. Get started

```bash
brew install naufalafif/tap/approve-gate
approve setup       # root-owned install, CLI links, menu bar app (asks for Touch ID once)
approve pair        # scan the QR code with the phone app
```

Update with `brew upgrade approve-gate && approve setup`. Put `~/.local/bin/touchid-wrap` first on
your `PATH`; the menu bar app warns if a CLI skips it. Install the phone app from
[Releases](../../releases) (or add this repo to [Obtainium](https://obtainium.imranr.dev) for
updates).

Which calls are free and which ask lives in the rules. Change them in the menu bar app's Settings,
or with `approve rules` (for example `approve rules add kubectl`, `approve rules disable kubectl`):

```json
"hcloud": { "default": "gated", "free": ["server list*", "server describe*", "--help", "* --help"] }
```

## 7. What's inside

| Part | Where | Job |
|---|---|---|
| `approve` | [`mac/`](mac) (Swift) | Wrapper, approval, pairing, Claude Code hook. One binary. |
| Phone app | [`android/`](android) (Kotlin) | Shows the request, signs with your fingerprint |
| Fake phone | [`tools/fakephone.swift`](tools/fakephone.swift) | Same protocol in software, for tests |
| Tests | [`tests/`](tests) | Rule and hook decisions, plus a full pair-and-approve run over the relay |

Every push runs builds, the tests, and security scans (secrets, SAST, dependencies, workflows).
Details, protocol and commands: [docs/details.md](docs/details.md).

## Limits

- macOS and Android only.
- The default relay, ntfy.sh, is a free public service. You can self-host it: `approve pair --server https://your-ntfy`.
- Some Android phones (Xiaomi, for example) delay notifications while asleep unless you allow the app to run in the background.
