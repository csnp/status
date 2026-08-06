#!/bin/bash
# Break the check on purpose and require the case suite to notice.
#
# A suite that only ever sees a working check proves nothing about the suite. Each
# mutation below is a plausible way someone could write this wrong, several of them being
# exactly how the csnp-connect original was written. Every one must turn the suite red.
#
# Each mutation is verified to have actually changed the file before it is run. A sed that
# matched nothing would leave the shipped text in place and "pass" for no reason.
set -uo pipefail

WF="${1:?usage: mutations.sh <workflow.yml>}"
HARNESS="$(cd "$(dirname "$0")" && pwd)"
# Private root per run, same reasoning as cases.sh.
ROOT="$(mktemp -d)"
MUTANT="$ROOT/mutant.yml"
MUTLOG="$ROOT/mut.log"
trap 'rm -rf "$ROOT"' EXIT

PASS=0; FAIL=0

mutate() {
  local name="$1" expr="$2"
  cp "$WF" "$MUTANT"
  perl -0777 -pi -e "$expr" "$MUTANT"

  if cmp -s "$WF" "$MUTANT"; then
    FAIL=$((FAIL+1))
    printf '  VOID  %-52s mutation matched nothing, so nothing was tested\n' "$name"
    return
  fi
  if ! python3 -c "import yaml,sys; yaml.safe_load(open('$MUTANT'))" 2>/dev/null; then
    FAIL=$((FAIL+1))
    printf '  VOID  %-52s mutant is not valid YAML, so the suite fails for the wrong reason\n' "$name"
    return
  fi

  if bash "$HARNESS/cases.sh" "$MUTANT" >"$MUTLOG" 2>&1; then
    FAIL=$((FAIL+1))
    printf '  SURVIVED  %-48s the suite passed a broken check\n' "$name"
  else
    PASS=$((PASS+1))
    local n; n="$(grep -c '^  FAIL' "$MUTLOG" || true)"
    printf '  caught    %-48s (%s case(s) went red)\n' "$name" "$n"
  fi
}

# The control. Without it every number below is worthless: mutations.sh scores a mutation
# as caught whenever the suite goes red, and the suite also goes red when the harness
# itself breaks. A port that failed to bind, a missing python3-yaml, a bad path, would all
# turn every mutation green-looking. If the unmutated check does not PASS the suite, no
# mutation result means anything and this exits rather than reporting eleven successes.
echo "Control: the unmutated check must PASS the suite."
if bash "$HARNESS/cases.sh" "$WF" >"$MUTLOG" 2>&1; then
  echo "  control ok"
else
  echo "  CONTROL FAILED. The suite does not pass against the unmutated check, so a red"
  echo "  suite proves nothing about any mutation. Last 15 lines:"
  tail -15 "$MUTLOG" | sed 's/^/    /'
  exit 1
fi
echo ""

echo "Mutations. Each must turn the suite red."
echo ""

mutate "data-age comparison inverted" \
  's/-gt "\$MAX_DATA_AGE_H"/-lt "\$MAX_DATA_AGE_H"/'

mutate "data-age limit raised so nothing is ever stale" \
  's/MAX_DATA_AGE_H: 48/MAX_DATA_AGE_H: 999999/'

mutate "data-age question removed entirely" \
  's/if \[ "\$DATA_AGE_H" -gt "\$MAX_DATA_AGE_H" \]; then/if false; then/'

mutate "branch on curl exit status instead of the status code" \
  's/STATUS="\$\(curl -sS -o served -w .%\{http_code\}. --max-time 30 --max-filesize 10485760 "\$SITE\/\$WITNESS" 2>\/dev\/null\)"/curl -fsS -o served --max-time 30 "\$SITE\/\$WITNESS" 2>\/dev\/null \&\& STATUS=200 || STATUS=000/'

mutate "redirect verdict removed, redirects fall through to not-serving" \
  's/elif \[ "\$STATUS" -ge 300 \] 2>\/dev\/null && \[ "\$STATUS" -lt 400 \] 2>\/dev\/null; then/elif false; then/'

mutate "the 000-on-failure fallback that yields 000000" \
  's/STATUS="\$\(curl -sS -o served -w .%\{http_code\}. --max-time 30 --max-filesize 10485760 "\$SITE\/\$WITNESS" 2>\/dev\/null\)"/STATUS="\$(curl -sS -o served -w \x27%{http_code}\x27 --max-time 30 --max-filesize 10485760 "\$SITE\/\$WITNESS" 2>\/dev\/null || echo 000)"/'

mutate "the empty-status default removed" \
  's/\n *STATUS="\$\{STATUS:-000\}"//'

mutate "pages guard back to accepting any JSON, error bodies included" \
  's/jq -e .has\("commit"\). >\/dev\/null/jq -e . >\/dev\/null/'

mutate "runs guard back to accepting any JSON" \
  "s/jq -e '\\.workflow_runs' >\\/dev\\/null/jq -e . >\\/dev\\/null/"

mutate "monitor-health question removed" \
  's/if \[ "\$LAST_CONCLUSION" != "success" \]; then/if false; then/'

mutate "CDN window widened so a real mismatch is always excused" \
  's/if \[ "\$PAGES_AGE_MIN" -lt 30 \]; then/if [ "\$PAGES_AGE_MIN" -lt 999999 ]; then/'

mutate "sha guard dropped, an API string is handed straight to git" \
  's/if ! \[\[ "\$PAGES_COMMIT" =~ \^\[0-9a-f\]\{40\}\$ \]\]; then/if false; then/'

mutate "sha guard back to the line-based grep form" \
  's/! \[\[ "\$PAGES_COMMIT" =~ \^\[0-9a-f\]\{40\}\$ \]\]/! printf '%s' "\$PAGES_COMMIT" | grep -Eq '^[0-9a-f]{40}$'/'

mutate "pages build status never checked" \
  's/if \[ "\$PAGES_STATUS" != "built" \]; then/if false; then/'

mutate "verdict hardcoded to ok" \
  's/echo "verdict=drift" >> "\$GITHUB_OUTPUT"\n          else/echo "verdict=ok" >> "\$GITHUB_OUTPUT"\n          else/'

echo ""
echo "==================================================================="
echo "caught $PASS, not caught $FAIL"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
