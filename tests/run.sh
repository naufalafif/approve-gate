#!/bin/bash
# Checks the gate rules and the Claude Code hook against the expected decisions.
# Usage: tests/run.sh [path/to/approve]   (default mac/approve, built by `make build`)
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
bin="${1:-mac/approve}"
export APPROVE_NO_FORWARD=1   # test this build, not an installed root-owned copy
fail=0

while IFS=$'\t' read -r want cli args; do
  # shellcheck disable=SC2086
  got=$("$bin" check --rules mac/rules.example.json "$cli" $args)
  if [ "$got" != "$want" ]; then echo "FAIL gate: $cli $args: want $want, got $got"; fail=1; fi
done < <(grep -v '^#' tests/gate_cases.tsv)

while IFS=$'\t' read -r want cmd; do
  out=$(jq -n --arg c "$cmd" '{tool_input:{command:$c}}' | "$bin" hook --rules mac/rules.example.json --hcloud-active staging)
  got=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // empty')
  got=${got:-allow}
  if [ "$got" != "$want" ]; then echo "FAIL hook: $cmd: want $want, got $got"; fail=1; fi
done < <(grep -v '^#' tests/guard_cases.tsv)

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/.claude"
printf '{\n  "theme": "light",\n  "hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "~/bin/approve hook"}]}]}\n}\n' > "$tmp/.claude/settings.json"
while IFS=$'\t' read -r want input; do
  input=${input//SETTINGS/$tmp/.claude/settings.json}
  out=$(jq -n --argjson t "$input" '{tool_name:"Edit", tool_input:$t}' | "$bin" hook --rules mac/rules.example.json)
  got=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // empty')
  got=${got:-allow}
  if [ "$got" != "$want" ]; then echo "FAIL file tool: $input: want $want, got $got"; fail=1; fi
done < <(grep -v '^#' tests/file_tool_cases.tsv)

gates=$(grep -vc '^#' tests/gate_cases.tsv); hooks=$(grep -vc '^#' tests/guard_cases.tsv); files=$(grep -vc '^#' tests/file_tool_cases.tsv)
[ "$fail" = 0 ] && echo "ok: $gates gate cases, $hooks hook cases, $files file tool cases" || exit 1
