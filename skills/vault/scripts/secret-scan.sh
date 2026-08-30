#!/usr/bin/env bash
# secret-scan.sh — credential guard for the vault's push path (locked decision D6
# of the multi-machine design, ~/Vaults/pantheon/architecture/memory-vault-sync.md).
#
# WHY THIS EXISTS. The vault's job is capturing incident scars, and a token is
# exactly the kind of evidence that belongs in one ("the 401 was this token").
# The salience gate does not help: it filters for durability, not for secrets, so
# a credential quoted as evidence reads to it like a legitimate detail. Before
# 1.1.0 that was survivable — the store was committed by hand, 13 commits in its
# whole life, so a mistake sat on disk for weeks. Since 1.1.0 every sweep commits
# AND pushes unattended, which collapsed the gap between "an agent wrote a token
# into a node" and "it is in permanent git history on a remote" to a few seconds.
# The durability fix is what created this exposure; this is its other half.
#
# Deliberately regex, not gitleaks: the guard has to travel with the plugin to
# every machine, and a scanner that needs installing is one a second machine
# silently lacks. Deliberately NOT a git hook for the same reason — hooks are not
# cloned, so a pre-push in ~/Vaults would protect this machine only.
#
# Usage: secret-scan.sh <file>...
#   exit 0 = clean, exit 1 = findings printed to stdout (secrets always redacted)
#
# Escape hatches, because a guard people cannot get past is a guard they turn off:
#   - `vault-allow-secret` on the offending line or the line above it
#   - VAULT_SKIP_SECRET_SCAN=1 for a whole run

set -uo pipefail

[[ "${VAULT_SKIP_SECRET_SCAN:-}" == "1" ]] && exit 0

ALLOW_MARKER='vault-allow-secret'

# rule-name|extended-regex. Every pattern is prefix-anchored or structural, so a
# hit is high-confidence: these match the shape of a real credential, not the
# shape of prose about one.
RULES=(
  "figma-pat|figd_[A-Za-z0-9_-]{20,}"
  "gitlab-pat|glpat-[A-Za-z0-9_-]{20,}"
  "github-token|gh[pousr]_[A-Za-z0-9]{30,}"
  "anthropic-key|sk-ant-[A-Za-z0-9_-]{20,}"
  "openai-key|sk-(proj-)?[A-Za-z0-9]{40,}"
  "aws-access-key|AKIA[0-9A-Z]{16}"
  "atlassian-token|ATATT[A-Za-z0-9_=-]{20,}"
  "slack-token|xox[baprs]-[A-Za-z0-9-]{10,}"
  "jwt|eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"
  "private-key|-----BEGIN [A-Z ]*PRIVATE KEY-----"
  "dsn-inline-password|(postgres|postgresql|mysql|mongodb)(\+srv)?://[^:@/[:space:]]+:[^@[:space:]]+@"
)

# A value that is obviously a stand-in rather than a credential. Checked only for
# the generic assignment rule below, which is the one prone to false positives.
PLACEHOLDER='(<[^>]*>|\.\.\.|xxx+|\*\*\*+|redacted|example|changeme|your[-_]|dummy|fake|placeholder|secret_here|token_here)'

findings=0

redact() {   # never reprint a full credential in an error message
  local m="$1"
  if (( ${#m} > 10 )); then printf '%s…(%d chars)' "${m:0:6}" "${#m}"; else printf '%s' '…'; fi
}

allowed() {  # file, line-number → 0 if this hit is explicitly allowed
  local f="$1" ln="$2" here prev
  here=$(sed -n "${ln}p" "$f" 2>/dev/null)
  [[ "$here" == *"$ALLOW_MARKER"* ]] && return 0
  if (( ln > 1 )); then
    prev=$(sed -n "$((ln - 1))p" "$f" 2>/dev/null)
    [[ "$prev" == *"$ALLOW_MARKER"* ]] && return 0
  fi
  return 1
}

report() {   # file, line, rule, match
  allowed "$1" "$2" && return 0
  printf '%s:%s: %s — %s\n' "$1" "$2" "$3" "$(redact "$4")"
  findings=$((findings + 1))
}

for f in "$@"; do
  [[ -f "$f" ]] || continue
  # Skip anything that is not text (an embedded image would otherwise match by luck).
  if command -v file >/dev/null 2>&1; then
    case "$(file -b --mime-type "$f" 2>/dev/null)" in
      text/*|inode/x-empty|application/json|application/x-yaml) ;;
      *) continue ;;
    esac
  fi

  for rule in "${RULES[@]}"; do
    name="${rule%%|*}"; pat="${rule#*|}"
    while IFS=: read -r ln match; do
      [[ -n "$ln" ]] || continue
      report "$f" "$ln" "$name" "$match"
    # -e is load-bearing: the private-key pattern starts with '-' and grep would
    # otherwise parse it as a flag and silently match nothing.
    done < <(grep -nEo -e "$pat" "$f" 2>/dev/null || true)
  done

  # Generic `password = "…"` assignments. Narrower than the rules above on
  # purpose: it requires a quoted, space-free, non-placeholder value, because a
  # knowledge vault is full of prose that says the word "password".
  while IFS=: read -r ln match; do
    [[ -n "$ln" ]] || continue
    val="${match#*[:=]}"
    val="$(printf '%s' "$val" | tr -d '"'\''[:space:]')"
    (( ${#val} >= 12 )) || continue
    printf '%s' "$val" | grep -qiE "$PLACEHOLDER" && continue
    report "$f" "$ln" "credential-assignment" "$val"
  done < <(grep -nEio "(password|passwd|secret|api[_-]?key|access[_-]?token)[[:space:]]*[:=][[:space:]]*['\"][^'\"[:space:]]{12,}['\"]" "$f" 2>/dev/null || true)
done

if (( findings > 0 )); then
  echo "secret-scan: $findings potential credential(s) — NOT committing."
  echo "secret-scan: remove the value (describe it instead), or if it is genuinely not a secret,"
  echo "secret-scan: mark the line with '$ALLOW_MARKER' and say why."
  exit 1
fi
exit 0
