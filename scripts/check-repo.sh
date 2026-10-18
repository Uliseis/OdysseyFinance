#!/usr/bin/env bash
# Repository guards for the rules in CLAUDE.md that a grep can check. Runs in CI.
# Usage: scripts/check-repo.sh [base-ref]   (base-ref enables the per-change checks)
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"

fail=0
err() { printf '✗ %s\n' "$1"; [ $# -gt 1 ] && printf '%s\n' "$2" | sed 's/^/    /'; fail=1; }

hits=$(git grep -n '#Unique' -- Core App)
[ -n "$hits" ] && err "#Unique is not allowed; composite uniqueness lives in CoreSync (docs/decisions.md)" "$hits"

hits=$(git grep -nw 'Double' -- Core/Sources/CoreModel)
[ -n "$hits" ] && err "Double in CoreModel; money is Decimal" "$hits"

hits=$(git ls-files \
  | grep -E '\.(pem|p8|p12|key|cer|mobileprovision|csv|store|store-wal|store-shm|sqlite|ips|crash)$|(^|/)dump[^/]*\.json$|^DevData/' \
  | grep -v '^Tools/ImportFromPostgres/Tests/.*/Fixtures/')
[ -n "$hits" ] && err "files that must never be tracked (keys, statements, stores, dumps)" "$hits"

hits=$(git grep -nE '^[A-Za-z0-9+/]{64}$' -- . ':!**/package-lock.json')
[ -n "$hits" ] && err "possible private key material (bare 64-char base64 lines)" "$hits"

if [ $# -ge 1 ] && git rev-parse -q --verify "$1^{commit}" >/dev/null; then
  base=$1
  hits=$(git diff --name-only "$base"...HEAD -- Spec/)
  [ -n "$hits" ] && err "Spec/ is frozen" "$hits"

  hits=$(git log "$base"..HEAD --format='%h %B' | grep -iE '^(co-authored-by:.*(claude|anthropic)|claude-session:)')
  [ -n "$hits" ] && err "AI attribution trailer in a commit message" "$hits"
fi

[ $fail -eq 0 ] && echo "✓ repo guards passed"
exit $fail
