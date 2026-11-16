#!/bin/bash
# End-to-end with the test build and the fake phone, in system mode (the test build treats a folder
# you own as "root-owned"), over a local relay (tests/relay.py) so tests never use ntfy.sh, whose
# rate limit would otherwise also block your real phone approvals. Covers pairing, approvals, the
# credential broker with a dummy Keychain secret, and tampering.
# Uses a temporary config folder and its own Keychain service (approve-gate-test); the real pairing,
# rules and secrets are never touched, and the shipped binary is never run here.
# Usage: tests/e2e.sh   (after `make build test-build`)
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
bin="$PWD/mac/approve-test"
phone="$PWD/tools/fakephone"
work=$(mktemp -d)
sys="$work/config/system"
# APPROVE_E2E_RELAY=https://your-relay runs the same steps against a deployed relay (relay/).
relay=""
if [ -n "${APPROVE_E2E_RELAY:-}" ]; then
  server="$APPROVE_E2E_RELAY"
else
  port=$(( 20000 + RANDOM % 20000 ))
  python3 -I tests/relay.py "$port" & relay=$!
  server="http://127.0.0.1:$port"
  for _ in $(seq 20); do curl -s -o /dev/null "$server/up/json?poll=1" && break; sleep 0.2; done
fi
cleanup() { APPROVE_TEST_TERMINAL=1 "$bin" secret rm e2e-key > /dev/null 2>&1; pkill -f "$work" 2>/dev/null; [ -n "$relay" ] && kill "$relay" 2>/dev/null; rm -rf "$work"; }
trap cleanup EXIT
export APPROVE_TEST_DIR="$work/config" APPROVE_TEST_SYSTEM=1 APPROVE_NO_MAC=1 APPROVE_TIMEOUT=15
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want $2, got $3"; fail=1; fi; }
yn() { if "$@"; then echo yes; else echo no; fi; }
# One fake phone answer at a time: stop any phone left from an earlier step, and start in a new second
# (the fake phone ignores requests created before the second it starts), so an earlier request that
# is still on the relay cannot be answered instead of the next one.
serve() {
  pkill -f "$work/phone.json serve" 2>/dev/null; sleep 1.1
  "$phone" "$work/phone.json" serve "$1" >> "$work/phone.log" 2>&1 & sleep 2
}

# The shipped binary must not contain the test-only overrides.
check "shipped binary has no test overrides" no "$(yn grep -q -e APPROVE_TEST_DIR -e APPROVE_TEST_TTY -e APPROVE_TEST_SYSTEM -e APPROVE_TEST_MAC -e APPROVE_TEST_TERMINAL -e TESTMAC <(strings mac/approve))"

# The "root-owned" settings folder, with a fake CLI named stripe that prints what it was given.
mkdir -p "$sys/home/stripe" "$work/links" "$work/real" "$work/evil"
chmod 755 "$sys" "$sys/home" "$sys/home/stripe"
cat > "$work/real/stripe" <<'EOF'
#!/bin/sh
echo "REAL ran: $* | key=${STRIPE_API_KEY:-none} | home=$HOME | foo=${FOO:-unset}"
EOF
printf '#!/bin/sh\necho "EVIL ran"\n' > "$work/evil/stripe"
chmod +x "$work/real/stripe" "$work/evil/stripe"
ln -s "$bin" "$work/links/stripe"
jq --arg p "$work/real/stripe" '.clis.stripe += {path: $p, env: {STRIPE_API_KEY: "secret:e2e-key"}}' \
  mac/rules.example.json > "$sys/rules.json"
chmod 644 "$sys/rules.json"
run() { PATH="$work/links:$work/evil:/usr/bin:/bin" stripe "$@" 2>&1; }

# Pairing: terminal only, nothing on disk while waiting, saved through the protected writer.
out=$(APPROVE_TEST_TTY=1 "$bin" pair < /dev/null 2>&1); rc=$?
check "pair without a terminal is refused" "1 yes" "$rc $(yn grep -q 'yourself in a terminal' <<<"$out")"
out=$("$bin" pair --server "$server" < /dev/null 2>&1); rc=$?
check "first pairing without Touch ID or a terminal is refused" "1 yes no" "$rc $(yn grep -q 'needs Touch ID or a terminal' <<<"$out") $(yn test -e "$sys/config.json")"
out=$(APPROVE_TEST_MAC=deny "$bin" pair --server "$server" < /dev/null 2>&1); rc=$?
check "first pairing denied on the Mac is refused, and the Mac was asked with the full command" "1 yes no" "$rc $(yn grep -q 'TESTMAC.*approve pair --server' <<<"$out") $(yn test -e "$sys/config.json")"
APPROVE_TEST_TERMINAL=1 "$bin" pair --link --server "$server" > "$work/pair.out" 2>&1 &
for _ in $(seq 40); do grep -q '^PAIRLINK ' "$work/pair.out" 2>/dev/null && break; sleep 0.5; done
check "no key on disk while waiting for the phone" no "$(yn test -e "$sys/config.json" -o -e "$work/config/pair.png")"
"$phone" "$(sed -n 's/^PAIRLINK //p' "$work/pair.out")" "$work/phone.json" pair > /dev/null
for _ in $(seq 30); do grep -q '^Paired with' "$work/pair.out" && break; sleep 1; done
check "pair output has no warnings" 0 "$(grep -c colorspace "$work/pair.out")"
check "pair prints a QR code" yes "$(yn grep -q '█' "$work/pair.out")"
check "paired, saved in the system folder" "yes 640" "$(yn grep -q '^Paired with fakephone' "$work/pair.out") $(stat -f %Lp "$sys/config.json" 2>/dev/null)"
check "the Mac shows the phone's pairing code before saving" yes "$(yn grep -q '^A phone answered with pairing code [0-9]\{3\} [0-9]\{3\} ' "$work/pair.out")"

# Secrets: stored in the Keychain, only this binary reads them.
serve approve
echo "sk_test_e2e_dummy" | "$bin" secret set e2e-key > /dev/null 2>&1
check "secret stored (name listed)" yes "$("$bin" secret list | yn grep -qx e2e-key)"
# The item's access list must trust only this binary. Read without asking for the value, so no
# Keychain prompt appears; trying to read it from another program would show one.
acl=$(security dump-keychain -a 2>/dev/null | awk -v RS='keychain: ' '/"svce"<blob>="approve-gate-test"/ && /"acct"<blob>="e2e-key"/' \
      | grep -E '^ +[0-9]+: /' | sort -u)
check "secret is trusted to this binary only" "1 yes" "$(grep -c . <<<"$acl") $(yn grep -qF "$bin" <<<"$acl")"
if [ "${APPROVE_E2E_PROMPT_PROBE:-0}" = 1 ]; then
  # Manual check: another program trying to read the value gets a Keychain prompt (press Deny).
  other=$(perl -e 'alarm 10; exec @ARGV' security find-generic-password -s approve-gate-test -a e2e-key -w 2>/dev/null)
  check "another program cannot read the secret" "" "$other"
fi

# Broker: free call gets the secret, from the fixed path, in a clean environment.
out=$(FOO=1 run --version)
check "free call runs the real CLI, not the one on PATH" yes "$(yn grep -q '^REAL ran' <<<"$out")"
check "free call gets the secret" yes "$(yn grep -q 'key=sk_test_e2e_dummy' <<<"$out")"
check "isolated HOME" yes "$(yn grep -q "home=$sys/home/stripe" <<<"$out")"
check "caller's environment is not passed on" yes "$(yn grep -q 'foo=unset' <<<"$out")"

# Approvals.
for mode in approve deny badsig ignore; do
  serve "$mode"
  out=$(run customers list); rc=$?
  case "$mode" in
    approve) check "phone approves: CLI runs with the secret" "0 yes" "$rc $(yn grep -q 'key=sk_test_e2e_dummy' <<<"$out")" ;;
    *)       check "phone $mode: CLI blocked" "1 no" "$rc $(yn grep -q 'REAL ran' <<<"$out")" ;;
  esac
done

# A flag that points the CLI elsewhere makes even a free call ask.
serve ignore
out=$(run --version --api-base=https://example.invalid); rc=$?
check "redirect flag on a free call asks (unanswered: blocked)" "1 no" "$rc $(yn grep -q 'REAL ran' <<<"$out")"

# Settings from the rules (what the menu bar app edits): the answer timeout, and the relay for pairing.
cp "$sys/rules.json" "$work/rules.saved"
jq '.approval = {timeoutSeconds: 10}' "$work/rules.saved" > "$sys/rules.json"
serve ignore
start=$(date +%s); out=$(run customers list); took=$(( $(date +%s) - start ))
check "timeout from the rules (10 s) is used" yes "$(yn test "$took" -ge 9 -a "$took" -le 13)"
jq --arg s "$server" '.relay = {server: $s}' "$work/rules.saved" > "$sys/rules.json"
serve approve # approve the re-pair, read the relay from the link, then stop before anything changes
APPROVE_TEST_TERMINAL=1 "$bin" pair --link > "$work/relaypair.out" 2>&1 &
for _ in $(seq 40); do grep -q '^PAIRLINK ' "$work/relaypair.out" 2>/dev/null && break; sleep 0.5; done
pkill -f "$bin pair --link" 2>/dev/null
link=$(sed -n 's/^PAIRLINK //p' "$work/relaypair.out")
check "pair without --server uses the relay from the rules" yes "$(yn grep -qF "s=${server}" <<<"$(python3 -c 'import sys,urllib.parse;print(urllib.parse.unquote(sys.argv[1]))' "$link")")"
check "stopping a pairing midway leaves the old one" yes "$("$bin" status | yn grep -q '^Paired with fakephone')"
cp "$work/rules.saved" "$sys/rules.json"

# Hidden characters and very long commands are shown, not hidden.
serve deny
long=$(printf 'x%.0s' $(seq 5000))
run customers update cus_1 "--name=safe$(printf '‮')txt.exe" "$long" > /dev/null
last=$(tail -1 "$work/config/approve.log")
check "bidi override shown as \\u{202e}" yes "$(yn grep -qF '\u{202e}' <<<"$last")"
check "long command says how much is hidden" yes "$(yn grep -q 'MORE CHARACTERS NOT SHOWN' <<<"$last")"

# Tampering: a rules file others can write is ignored, so every call asks.
chmod 664 "$sys/rules.json"
serve deny
out=$(run --version); rc=$?
check "tampered rules: free call asks (denied: blocked)" "1 no" "$rc $(yn grep -q 'REAL ran' <<<"$out")"
chmod 644 "$sys/rules.json"
chmod 775 "$sys/home/stripe"
out=$(run --version); rc=$?
check "isolated HOME others can write: refused" "1 no" "$rc $(yn grep -q 'REAL ran' <<<"$out")"
chmod 755 "$sys/home/stripe"
chmod 775 "$work/real"
out=$(run --version 2>&1); rc=$?
check "CLI with secrets in a folder others can write: refused" "127 no yes" "$rc $(yn grep -q 'REAL ran' <<<"$out") $(yn grep -q 'must be root-owned' <<<"$out")"
chmod 755 "$work/real"

# Missing secret: the CLI does not run.
serve approve
"$bin" secret rm e2e-key > /dev/null 2>&1
out=$(run --version); rc=$?
check "missing secret: CLI does not run" "1 yes" "$rc $(yn grep -q 'secret .e2e-key. is not set' <<<"$out")"

# The protected writer only writes the two settings files, with valid content.
echo '{}' > "$work/x.json"
xsum=$(shasum -a 256 "$work/x.json" | cut -d' ' -f1)
out=$("$bin" _install "$work/x.json" "$work/elsewhere.json" "$xsum" 2>&1); rc=$?
check "_install refuses other paths" "2 no" "$rc $(yn test -e "$work/elsewhere.json")"
out=$("$bin" _install "$work/x.json" "$sys/rules.json" "$xsum" 2>&1); rc=$?
check "_install refuses invalid rules" "2 yes" "$rc $(yn grep -q 'stripe' "$sys/rules.json")"
jq '.clis.swapped = {"free": ["*"]}' "$sys/rules.json" > "$work/swap.json"
out=$("$bin" _install "$work/swap.json" "$sys/rules.json" "$xsum" 2>&1); rc=$?
check "_install refuses a file that changed after approval" "2 yes no" "$rc $(yn grep -q 'changed after it was approved' <<<"$out") $(yn grep -q swapped "$sys/rules.json")"
jq '.clis.rd.free += ["jobs purge*"]' "$sys/rules.json" > "$work/new-rules.json"
"$bin" rules install "$work/new-rules.json" > /dev/null 2>&1
check "rules install replaces the rules (644)" "yes 644" "$(yn grep -q 'jobs purge' "$sys/rules.json") $(stat -f %Lp "$sys/rules.json")"
jq '.clis.newtool = {"free": []}' "$work/new-rules.json" > "$work/new-rules2.json"
"$bin" rules install "$work/new-rules2.json" > /dev/null 2>&1
jq '.clis["../escape"] = {"free": []}' "$work/new-rules.json" > "$work/new-rules3.json"
"$bin" rules install "$work/new-rules3.json" > /dev/null 2>&1
check "rules install creates a new command's home; a path-like name is refused" "yes no" "$(yn test -d "$sys/home/newtool") $(yn test -e "$sys/escape")"
"$bin" rules install "$work/new-rules.json" > /dev/null 2>&1

# approve rules: every change the Settings window makes, from the command line.
cp "$sys/rules.json" "$work/rules.saved"
jq '._comment = "kept"' "$work/rules.saved" > "$sys/rules.json"
lnk="$work/config/links"
r() { "$bin" rules "$@" < /dev/null > "$work/rules.out" 2>&1; }
j() { jq -S -c "$1" "$sys/rules.json"; }
mkdir -p "$lnk"; ln -s /bin/echo "$lnk/other"
"$bin" link > /dev/null
stripe_before=$(j '.clis.stripe | del(.disabled)')
check "rules show lists the commands" yes "$("$bin" rules show | yn grep -q '^  stripe')"
check "rules show CLI names Keychain secrets, not values" "yes no" "$("$bin" rules show stripe | yn grep -q 'from the Keychain (e2e-key)') $("$bin" rules show stripe | yn grep -q sk_test)"
check "rules templates --json has 16" 16 "$("$bin" rules templates --json | jq length)"
out=$(APPROVE_TEST_TTY=1 "$bin" rules disable stripe < /dev/null 2>&1); rc=$?
check "user mode without a terminal: refused, unchanged" "1 null" "$rc $(j .clis.stripe.disabled)"
r disable stripe
check "disable: rules kept, marked off" "true yes" "$(j .clis.stripe.disabled) $(yn test "$(j '.clis.stripe | del(.disabled)')" = "$stripe_before")"
check "disable: prints the diff" yes "$(yn grep -q '^+.*"disabled" : true' "$work/rules.out")"
check "disable: link removed, other links and non-approve links kept" "no yes yes" "$(yn test -L "$lnk/stripe") $(yn test -L "$lnk/vault") $(yn test -L "$lnk/other")"
check "check: off" "free (gating is off)" "$("$bin" check stripe customers delete cus_1)"
serve deny
out=$(run customers delete cus_1); rc=$?
check "off: runs without asking, and without the broker's secret" "0 yes" "$rc $(yn grep -q 'REAL ran: customers delete cus_1 | key=none' <<<"$out")"
hookp() { local d; d=$(jq -n --arg c "$1" '{tool_input:{command:$c}}' | "$bin" hook --hcloud-active staging | jq -r '.hookSpecificOutput.permissionDecision // empty'); echo "${d:-allow}"; }
check "hook: real binary by path allowed while off" allow "$(hookp '/opt/homebrew/bin/stripe customers list')"
check "status --json reports off" true "$("$bin" status --json | jq '.clis[] | select(.name=="stripe") | .disabled')"
r disable stripe
check "disable twice: nothing to change" yes "$(yn grep -q '^Nothing to change' "$work/rules.out")"
r enable stripe
check "enable: same rules as before, link back" "null yes yes" "$(j .clis.stripe.disabled) $(yn test "$(j .clis.stripe)" = "$stripe_before") $(yn test -L "$lnk/stripe")"
check "hook: real binary by path blocked again" deny "$(hookp '/opt/homebrew/bin/stripe customers list')"
r add kubectl
check "add: suggested list, flags, link" "11 3 yes" "$(j '.clis.kubectl.free | length') $(j '.clis.kubectl.gatedArgs | length') $(yn test -L "$lnk/kubectl")"
r add kubectl; rc=$?
check "add twice: refused" "yes" "$(yn grep -q 'already gated' "$work/rules.out")"
r add 'bad/name'
check "add a bad name: refused" null "$(j '.clis["bad/name"]')"
r add mytool --empty
check "add --empty: every call asks" "[] gated" "$(j .clis.mytool.free) $(j .clis.mytool.default | tr -d '"')"
r free kubectl add 'rollout status*'
check "free add" yes "$(yn test "$(j '.clis.kubectl.free | index("rollout status*")')" != null)"
r free kubectl rm 'rollout status*' 'get *'
check "free rm" "null null" "$(j '.clis.kubectl.free | index("rollout status*")') $(j '.clis.kubectl.free | index("get *")')"
r free kubectl reset
check "free reset" 11 "$(j '.clis.kubectl.free | length')"
r gated-arg kubectl rm '--server*' '--kubeconfig*' '--token*'
check "gated-arg rm all: key removed" null "$(j .clis.kubectl.gatedArgs)"
r gated-arg kubectl add '--context*'
check "gated-arg add" '["--context*"]' "$(j .clis.kubectl.gatedArgs)"
check "check uses the new rules" "gated free" "$("$bin" check kubectl get pods --context=prod) $("$bin" check kubectl get pods)"
r ask kubectl always
check "ask always" "[] gated" "$(j .clis.kubectl.free) $("$bin" check kubectl get pods)"
r ask kubectl reads
check "ask reads: suggested list back" 11 "$(j '.clis.kubectl.free | length')"
r remove kubectl
r remove mytool
check "remove: rules and links gone" "null no no" "$(j .clis.kubectl) $(yn test -L "$lnk/kubectl") $(yn test -L "$lnk/mytool")"
r remove kubectl
check "remove unknown: refused" yes "$(yn grep -q 'is not gated' "$work/rules.out")"
r timeout 5
check "timeout out of range: refused" null "$(j .approval.timeoutSeconds)"
r timeout 60; r ask-on-mac off
check "timeout and ask-on-mac" "60 false" "$(j .approval.timeoutSeconds) $(j .approval.askOnMac)"
r production add staging-prod; r production rm prod
check "production add and rm" "no yes" "$(yn test "$(j '.production | index("prod")')" != null) $(yn test "$(j '.production | index("staging-prod")')" != null)"
r relay http://evil.example
check "relay over plain http: refused" null "$(j .relay)"
r relay https://relay.example.com/
check "relay set (no trailing slash)" '"https://relay.example.com"' "$(j .relay.server)"
r relay default
check "relay default" null "$(j .relay)"
check "unknown fields kept, file still root-owned style (644)" '"kept" 644' "$(j ._comment) $(stat -f %Lp "$sys/rules.json")"
r bogus
check "unknown subcommand prints usage" yes "$(yn grep -q 'usage: approve rules' "$work/rules.out")"
mkdir -p "$work/config/claude"; printf '{"theme": "light"}\n' > "$work/config/claude/settings.json"
"$bin" hook install > "$work/hook.out" 2>&1
check "hook install: both matchers, other settings kept" "2 \"light\"" "$(jq '[.hooks.PreToolUse[] | select(.hooks[0].command == "~/bin/approve hook")] | length' "$work/config/claude/settings.json") $(jq .theme "$work/config/claude/settings.json")"
"$bin" hook install > "$work/hook.out" 2>&1
check "hook install twice: already on" yes "$(yn grep -q 'already on' "$work/hook.out")"
cp "$work/rules.saved" "$sys/rules.json"

# Settings helper: changes go through Approve Gate's own approval (here the fake phone) and the helper,
# which only accepts the "root-owned" approve binary (same code hash, hardened runtime) as its caller.
sysbin="$work/config/libexec/approve-gate/approve"
mkdir -p "$(dirname "$sysbin")"; chmod 755 "$work/config/libexec" "$(dirname "$sysbin")"
cp "$bin" "$sysbin"
# A secret stored in the Keychain before the helper runs (by this same binary, so no Keychain prompt).
serve approve
echo "sk_moved" | "$sysbin" secret set e2e-key > "$work/s0.out" 2>&1
"$sysbin" _helper 2> "$work/helper.log" &
for _ in $(seq 20); do [ -S "$work/config/helper.sock" ] && break; sleep 0.2; done
check "helper: listening" yes "$(yn test -S "$work/config/helper.sock")"
mkdir -p "$work/hl"; ln -sf "$sysbin" "$work/hl/stripe"
hrun() { PATH="$work/hl:/usr/bin:/bin" stripe "$@" 2>&1; }
out=$(hrun --version)
check "secret moved from the Keychain to the root store on first use" "yes yes 600 700 no" "$(yn grep -q 'key=sk_moved' <<<"$out") $(yn grep -q 'moved secret e2e-key' <<<"$out") $(stat -f %Lp "$sys/secrets/e2e-key" 2>/dev/null) $(stat -f %Lp "$sys/secrets" 2>/dev/null) $(APPROVE_TEST_SYSTEM='' "$bin" secret list | yn grep -qx e2e-key)"
serve approve
echo "sk_rootstore" | "$sysbin" secret set e2e-key > "$work/s1.out" 2>&1
out=$(hrun --version)
check "secret set goes to the root store; the CLI gets the new value" "yes yes no" "$(yn grep -q 'root-owned store' "$work/s1.out") $(yn grep -q 'key=sk_rootstore' <<<"$out") $(yn grep -q 'moved secret' <<<"$out")"
check "secret list through the helper" yes "$("$sysbin" secret list | yn grep -qx e2e-key)"
out=$(python3 -I - "$work/config/helper.sock" <<'PY'
import json, socket, sys
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1])
s.sendall(json.dumps({"op": "secret-get", "name": "e2e-key"}).encode()); s.shutdown(socket.SHUT_WR)
print(s.recv(4096).decode())
PY
)
check "another program cannot read a secret from the helper" "yes no" "$(yn grep -q 'refused' <<<"$out") $(yn grep -q 'ok ' <<<"$out")"
serve approve
"$sysbin" secret rm e2e-key > "$work/s2.out" 2>&1
check "secret rm removes it from the root store" no "$(yn test -e "$sys/secrets/e2e-key")"
check "status names Touch ID for settings changes" yes "$("$sysbin" status | yn grep -q 'Settings changes: Touch ID or the phone')"
cp "$sys/rules.json" "$work/rules.saved"
serve approve
"$sysbin" rules disable stripe < /dev/null > "$work/h1.out" 2>&1; rc=$?
check "helper: approved change written (644)" "0 true 644" "$rc $(j .clis.stripe.disabled) $(stat -f %Lp "$sys/rules.json")"
check "helper: the phone was shown what the change does" yes "$(yn grep -q '"reason":"turn gating off for stripe (rules kept)"' "$work/phone.log")"
jq '.clis.newtool2 = {"free": ["*"], "path": "/bin/echo", "env": {"K": "secret:x"}}' "$sys/rules.json" > "$work/inst.json"
serve approve
"$sysbin" rules install "$work/inst.json" < /dev/null > "$work/h1b.out" 2>&1
check "helper: rules install names what it changes" "yes yes" "$(yn grep -qF 'change its rules: gate newtool2 (path' "$work/phone.log") $(yn grep -qF 'EVERYTHING FREE' "$work/phone.log")"
# The summary shows old and new values, changes to existing commands first; too long is refused.
jq '.clis.stripe.default = "free" | .clis.stripe.env.STRIPE_API_BASE = "https://evil.example"' "$sys/rules.json" > "$work/inst2.json"
serve deny
"$sysbin" rules install "$work/inst2.json" < /dev/null > "$work/h1d.out" 2>&1
check "helper: summary names the new values and EVERYTHING FREE" "yes yes" "$(yn grep -qF 'stripe: default gated -> free' "$work/phone.log") $(yn grep -qF 'EVERYTHING FREE' <(grep 'stripe: default' "$work/phone.log"))"
jq '.clis += ([range(30)] | map({key: "padcli\(.)", value: {free: []}}) | from_entries) | .clis.stripe.free += ["*"]' "$sys/rules.json" > "$work/inst3.json"
out=$("$sysbin" rules install "$work/inst3.json" < /dev/null 2>&1); rc=$?
check "helper: a summary too long for the prompt is refused, not cut" "1 yes" "$rc $(yn grep -q 'too long to show' <<<"$out")"
out=$(jq '.clis["bad name"] = {free: []}' "$sys/rules.json" > "$work/inst4.json"; "$sysbin" rules install "$work/inst4.json" < /dev/null 2>&1); rc=$?
check "rules install refuses a bad command name" "2 yes" "$rc $(yn grep -q 'is not a command name' <<<"$out")"
# Pairing another key asks again, naming that key's code; denying it keeps the current pairing.
pk_before=$(jq -r .phonePublicKey "$sys/config.json")
serve approve
"$sysbin" pair --link --server "$server" < /dev/null > "$work/h1c.out" 2>&1 &
for _ in $(seq 40); do grep -q '^PAIRLINK ' "$work/h1c.out" 2>/dev/null && break; sleep 0.5; done
serve deny
"$phone" "$(sed -n 's/^PAIRLINK //p' "$work/h1c.out")" "$work/phone2.json" pair > /dev/null 2>&1
for _ in $(seq 30); do grep -q 'Not paired with that phone' "$work/h1c.out" && break; sleep 0.5; done
pkill -f "$sysbin pair --link" 2>/dev/null
check "helper: a new phone's key needs its own approval, showing its code; denied keeps the pairing" "yes yes yes" "$(yn grep -q '"reason":"pairing code [0-9]\{3\} [0-9]\{3\}: approve only if your phone shows this code' "$work/phone.log") $(yn grep -q 'Not paired with that phone' "$work/h1c.out") $(yn test "$(jq -r .phonePublicKey "$sys/config.json")" = "$pk_before")"
serve deny
"$sysbin" rules enable stripe < /dev/null > "$work/h2.out" 2>&1; rc=$?
check "helper: declined change not written" "1 true yes" "$rc $(j .clis.stripe.disabled) $(yn grep -q 'declined' "$work/h2.out")"
# Another program talking to the helper directly is refused.
python3 -I - "$work/config/helper.sock" "$sys/rules.json" > "$work/h3.out" 2>&1 <<'PY'
import base64, json, socket, sys
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1])
s.sendall(json.dumps({"dest": sys.argv[2], "data": base64.b64encode(b'{"clis":{}}').decode()}).encode())
s.shutdown(socket.SHUT_WR); print(s.recv(4096).decode())
PY
check "helper: another program is refused" "yes true" "$(yn grep -q 'refused: caller is not' "$work/h3.out") $(j .clis.stripe.disabled)"
# A copy of approve with a different signature (not the installed build) is refused, after approval.
cp "$bin" "$work/approve-other"; codesign --force --sign - "$work/approve-other" 2>/dev/null
serve approve
"$work/approve-other" rules enable stripe < /dev/null > "$work/h4.out" 2>&1; rc=$?
check "helper: a differently signed approve is refused" "1 yes true" "$rc $(yn grep -q 'refused' "$work/h4.out") $(j .clis.stripe.disabled)"
check "helper: only content that parses is accepted" yes "$(cd "$work" && echo '{"clis":' > bad.json; "$sysbin" rules install bad.json < /dev/null 2>&1 | yn grep -qi 'not valid\|invalid\|parse')"
# Unsigned-runtime install: the helper refuses everything.
codesign --force --sign - "$sysbin" 2>/dev/null
serve approve
"$sysbin" rules enable stripe < /dev/null > "$work/h5.out" 2>&1
check "helper: refuses when the installed approve lacks the hardened runtime" "yes true" "$(yn grep -q 'hardened runtime' "$work/h5.out") $(j .clis.stripe.disabled)"
pkill -f "$sysbin _helper"; sleep 0.3; rm -f "$work/config/helper.sock"
cp "$work/rules.saved" "$sys/rules.json"
[ "$fail" = 0 ] || { echo "--- helper log:"; cat "$work/helper.log"; echo "--- phone reasons:"; grep -o "\"reason\":\"[^\"]*" "$work/phone.log" | tail -5; for f in h1 h1b h1c h2 h3 h4 h5; do echo "--- $f:"; cat "$work/$f.out"; done; }

# Changing the pairing needs an approval.
serve deny
APPROVE_TEST_TERMINAL=1 "$bin" pair --link --server "$server" > "$work/repair.out" 2>&1; rc=$?
check "re-pair denied: refused" "1 yes" "$rc $(yn grep -q 'nothing changed' "$work/repair.out")"
serve deny
"$bin" unpair > /dev/null 2>&1
check "unpair denied: still paired" yes "$("$bin" status | yn grep -q '^Paired with fakephone')"
serve approve
"$bin" unpair > "$work/unpair.out" 2>&1
check "unpair approved: removed from the system folder" "yes no" "$("$bin" status | yn grep -q '^Not paired') $(yn test -e "$sys/config.json")"
out=$(printf 'x\n' | APPROVE_TEST_TERMINAL=1 "$bin" secret set e2e-unpaired 2>&1); rc=$?
check "unpaired without Touch ID: a terminal does not approve a secret change" "1 yes no" "$rc $(yn grep -q 'needs Touch ID or the phone' <<<"$out") $("$bin" secret list | yn grep -qx e2e-unpaired)"
[ "$fail" = 0 ] || { echo "--- unpair output:"; cat "$work/unpair.out"; echo "--- phone log:"; tail -5 "$work/phone.log"; }

# approve setup, root part: into a fresh test folder, from a fake home with rules and a pairing.
setup="$work/setup"; fakehome="$work/fakehome"
mkdir -p "$fakehome/.config/approve-gate"
cp mac/rules.example.json "$fakehome/.config/approve-gate/rules.json"
printf '{"server":"https://relay.example","reqTopic":"ag-a","resTopic":"ag-b","key":"k","phonePublicKey":"p","phoneName":"Fake"}' \
  > "$fakehome/.config/approve-gate/config.json"
APPROVE_TEST_DIR="$setup" "$bin" _setup-root "$fakehome" mac/rules.example.json > /dev/null 2>&1; rc=$?
ssys="$setup/system"
check "setup: finishes" 0 "$rc"
check "setup: binary installed (755)" 755 "$(stat -f %Lp "$setup/libexec/approve-gate/approve" 2>/dev/null)"
check "setup: rules installed (644)" 644 "$(stat -f %Lp "$ssys/rules.json" 2>/dev/null)"
check "setup: an isolated home per CLI" 6 "$(find "$ssys/home" -mindepth 1 -maxdepth 1 -type d | grep -c .)"
check "setup: a pairing in the home folder is never imported" no "$(yn test -e "$ssys/config.json")"
# A rules file that is a symlink is refused, so root never copies or chowns what it points at.
setup2="$work/setup2"; fakehome2="$work/fakehome2"
mkdir -p "$fakehome2/.config/approve-gate"
echo private > "$work/target-file"; chmod 600 "$work/target-file"
ln -s "$work/target-file" "$fakehome2/.config/approve-gate/rules.json"
APPROVE_TEST_DIR="$setup2" "$bin" _setup-root "$fakehome2" mac/rules.example.json > /dev/null 2>&1; rc=$?
check "setup: symlinked rules refused, link target untouched" "1 no 600" "$rc $(yn test -e "$setup2/system/rules.json") $(stat -f %Lp "$work/target-file")"

check "no Mac approvals: the test build plays Touch ID, the suite only denies on it" 0 "$(grep -c 'decision=approved via=mac' "$work/config/approve.log" 2>/dev/null || true)"
[ "$fail" = 0 ] && echo "e2e ok" || exit 1
