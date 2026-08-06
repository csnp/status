#!/bin/bash
# Drive the shipped run: block against controlled inputs, and require it to notice.
#
# Every case states the verdict it expects and a phrase that must appear in failures.txt,
# plus, where it matters, a phrase that must NOT appear. The must-not half is the point:
# a check that shouts "drift" for every reason at once is not distinguishing anything, and
# the redirect-versus-malformed confusion this whole family of checks exists to avoid
# would pass a test that only asserted "drift".
set -uo pipefail

WF="$1"
HARNESS="$(cd "$(dirname "$0")" && pwd)"
# One private root per run, removed on exit. Fixed /tmp paths are a symlink-attack
# surface (CWE-377) and, more mundanely, they make two concurrent runs of this harness
# silently share a work directory and report each other's results.
ROOT="$(mktemp -d)"
WORK="$ROOT/case"
CTL="$ROOT/ctl"
CHECK="$ROOT/check.sh"
CHECKENV="$ROOT/check.env"
NOCURL="$ROOT/nocurl"
PORT=8099
mkdir -p "$CTL"
cleanup() { [ -n "${SRV:-}" ] && kill "$SRV" 2>/dev/null; rm -rf "$ROOT"; }
trap cleanup EXIT

python3 "$HARNESS/extract.py" "$WF" > "$CHECK" || { echo "EXTRACT FAILED"; exit 1; }
python3 "$HARNESS/extract.py" "$WF" env > "$CHECKENV" || { echo "ENV EXTRACT FAILED"; exit 1; }
echo "extracted $(wc -l < "$CHECK") lines of the shipped run: block"

# The shipped values, not the harness's idea of them. SITE is the one thing that has to be
# overridden, because the cases need an address they can make misbehave.
set -a; . "$CHECKENV"; set +a
echo "shipped: MAX_DATA_AGE_H=$MAX_DATA_AGE_H WITNESS=$WITNESS SITE=$SITE (SITE overridden below)"

# The check calls `gh`, so the stub has to be installed under that name. Naming it
# anything else makes every gh call fall through to "could not be read", which reports
# drift for the wrong reason and looks exactly like a check that works.
STUBBIN="$ROOT/stubbin"
mkdir -p "$STUBBIN"
cp "$HARNESS/gh-stub" "$STUBBIN/gh"
chmod +x "$STUBBIN/gh"
# On a hosted runner the real gh is already on PATH, so it is not enough to add the stub;
# the stub has to win. Asserted rather than assumed, because a real gh here would make
# every case query GitHub and the suite would measure the wrong thing entirely.
export PATH="$STUBBIN:$PATH"
RESOLVED="$(command -v gh || true)"
if [ "$RESOLVED" != "$STUBBIN/gh" ]; then
  echo "gh resolves to '$RESOLVED', not the stub at $STUBBIN/gh. Refusing to run."
  exit 1
fi

PASS=0; FAIL=0
declare -a FAILED_CASES=()

setup_repo() {
  local data_age_h="$1"
  rm -rf "$WORK"; mkdir -p "$WORK"; cd "$WORK" || exit 1
  git init -q -b main .
  git config user.email bot@example.com; git config user.name Bot
  mkdir -p history
  echo "<html>witness</html>" > index.html
  echo "url: x" > history/site.yml
  local when
  when="$(date -u -d "@$(( $(date -u +%s) - data_age_h * 3600 ))" '+%Y-%m-%dT%H:%M:%S+0000')"
  GIT_AUTHOR_DATE="$when" GIT_COMMITTER_DATE="$when" git add -A
  GIT_AUTHOR_DATE="$when" GIT_COMMITTER_DATE="$when" git commit -qm "data"
  git update-ref refs/remotes/origin/main HEAD
  PAGES_SHA="$(git rev-parse HEAD)"
}

run_case() {
  local name="$1" want_verdict="$2" want_phrase="$3" not_phrase="${4:-}"
  cd "$WORK" || exit 1
  : > GITHUB_OUTPUT_FILE
  GITHUB_OUTPUT="$WORK/GITHUB_OUTPUT_FILE" \
  GITHUB_REPOSITORY="csnp/status" \
  GITHUB_REF_NAME="main" \
  GH_TOKEN="x" \
  SITE="http://127.0.0.1:$PORT" \
  WITNESS="$WITNESS" \
  MAX_DATA_AGE_H="$MAX_DATA_AGE_H" \
  ISSUE_TITLE="t" \
  PATH="$STUBBIN:$PATH" \
  bash "$CHECK" > case.log 2>&1

  local got; got="$(grep -o 'verdict=[a-z-]*' GITHUB_OUTPUT_FILE | tail -1 | cut -d= -f2)"
  local ok=1
  [ "$got" = "$want_verdict" ] || ok=0
  if [ -n "$want_phrase" ]; then grep -qF "$want_phrase" failures.txt 2>/dev/null || ok=0; fi
  if [ -n "$not_phrase" ]; then ! grep -qF "$not_phrase" failures.txt 2>/dev/null || ok=0; fi

  if [ "$ok" = 1 ]; then
    PASS=$((PASS+1)); printf '  PASS  %-46s verdict=%s\n' "$name" "$got"
  else
    FAIL=$((FAIL+1)); FAILED_CASES+=("$name")
    printf '  FAIL  %-46s verdict=%s (wanted %s)\n' "$name" "${got:-<none>}" "$want_verdict"
    echo "        wanted phrase: $want_phrase"
    [ -n "$not_phrase" ] && echo "        forbidden phrase: $not_phrase"
    echo "        --- failures.txt ---"; sed 's/^/        /' failures.txt 2>/dev/null | head -6
    echo "        --- stdout ---"; sed 's/^/        /' case.log | head -8
  fi
}

good_runs()    { echo '{"workflow_runs":[{"conclusion":"success","created_at":"2026-08-05T12:00:00Z"}]}' > CASE_RUNS; echo '{"workflow_runs":[{"created_at":"2026-08-05T12:00:00Z"}]}' > CASE_RUNS_SUCCESS; }
broken_runs()  { echo '{"workflow_runs":[{"conclusion":"failure","created_at":"2026-08-05T12:00:00Z"}]}' > CASE_RUNS; echo '{"workflow_runs":[{"created_at":"2026-06-17T01:14:00Z"}]}' > CASE_RUNS_SUCCESS; }
good_pages()   { printf '{"status":"built","commit":"%s","updated_at":"%s"}\n' "$PAGES_SHA" "$(date -u -d '-3 hours' +%Y-%m-%dT%H:%M:%SZ)" > CASE_PAGES; }
fresh_pages()  { printf '{"status":"built","commit":"%s","updated_at":"%s"}\n' "$PAGES_SHA" "$(date -u -d '-2 minutes' +%Y-%m-%dT%H:%M:%SZ)" > CASE_PAGES; }
serve_ok()     { git show HEAD:index.html > "$CTL/CASE_BODY"; echo 200 > "$CTL/CASE_STATUS"; }

# --------------------------------------------------------------------------------------
setup_repo 3
echo 200 > "$CTL/CASE_STATUS"; echo x > "$CTL/CASE_BODY"
( cd "$CTL" && python3 "$HARNESS/server.py" "$PORT" ) & SRV=$!
sleep 1

echo ""
echo "Baseline: everything healthy. If this is not ok, every failure below is meaningless."
good_runs; good_pages; serve_ok
run_case "healthy" "ok" ""

echo ""
echo "A. the data stopped, which is the outage that actually happened"
setup_repo 1176   # 49 days, the real duration
good_runs; good_pages; serve_ok
run_case "the real 49-day outage is caught at ANY shipped limit" "drift" "hours ago, against a limit of"

setup_repo $(( MAX_DATA_AGE_H - 1 ))
good_runs; good_pages; serve_ok
run_case "data $(( MAX_DATA_AGE_H - 1 ))h, just inside the shipped limit" "ok" ""

setup_repo $(( MAX_DATA_AGE_H + 1 ))
good_runs; good_pages; serve_ok
run_case "data $(( MAX_DATA_AGE_H + 1 ))h, just outside the shipped limit" "drift" "against a limit of $MAX_DATA_AGE_H"

echo ""
echo "A2. the shipped threshold has to stay defensible on its own"
# Measured over the 60 healthy days to 2026-06-17: max observed gap between history/
# commits was 22.57h. Below 24h the check would fire on a normal quiet day; above a week
# it stops being a monitor. Neither bound is a preference, and a future edit that leaves
# this range has to justify itself here rather than silently.
if [ "$MAX_DATA_AGE_H" -ge 24 ] && [ "$MAX_DATA_AGE_H" -le 168 ]; then
  PASS=$((PASS+1)); printf '  PASS  %-46s %sh\n' "threshold within 24h..168h" "$MAX_DATA_AGE_H"
else
  FAIL=$((FAIL+1)); FAILED_CASES+=("threshold out of range")
  printf '  FAIL  %-46s %sh is outside 24h..168h\n' "threshold within 24h..168h" "$MAX_DATA_AGE_H"
fi

echo ""
echo "B. the monitor itself"
setup_repo 3
broken_runs; good_pages; serve_ok
run_case "uptime.yml failing" "drift" "last finished 'failure'"

setup_repo 3
good_runs; good_pages; serve_ok; echo "runs?per_page" > CASE_GH_FAIL
run_case "run history unreadable, says so" "drift" "whether the monitor is running is unknown"
rm -f CASE_GH_FAIL

echo ""
echo "C. the domain. The redirect case is the one that must not read as a content fault."
setup_repo 3
good_runs; good_pages; serve_ok; echo 307 > "$CTL/CASE_STATUS"
run_case "domain answers 307" "drift" "a redirect" "is not serving the site"

setup_repo 3
good_runs; good_pages; serve_ok; echo 404 > "$CTL/CASE_STATUS"
run_case "domain answers 404" "drift" "answered HTTP 404" "a redirect"

setup_repo 3
good_runs; good_pages; serve_ok; echo "changed bytes" > "$CTL/CASE_BODY"
run_case "served bytes differ, build old" "drift" "does not match the one committed"

setup_repo 3
good_runs; fresh_pages; serve_ok; echo "changed bytes" > "$CTL/CASE_BODY"
run_case "served bytes differ, inside CDN window" "ok" ""

setup_repo 3
good_runs; serve_ok
printf '{"status":"errored","commit":"%s","updated_at":"%s"}\n' "$PAGES_SHA" "$(date -u -d '-3 hours' +%Y-%m-%dT%H:%M:%SZ)" > CASE_PAGES
run_case "pages build errored" "drift" "not 'built'"

setup_repo 3
good_runs; serve_ok
echo '{"status":"built","commit":"not-a-sha","updated_at":"2026-08-05T00:00:00Z"}' > CASE_PAGES
run_case "pages commit not a sha, never reaches git" "drift" "no usable commit"

setup_repo 3
good_runs; good_pages; serve_ok; echo "pages/builds" > CASE_GH_FAIL
run_case "pages record unreadable, says so" "drift" "could not be read"
rm -f CASE_GH_FAIL

echo ""
echo "C2. a GitHub error body is valid JSON and has a .status. It is not a build record."
# This is the defect the pre-merge production render caught. gh api prints the error body
# to stdout and exits non-zero; the old code kept the body and read .status out of it, so
# a 404 was reported as "the most recent Pages build is '404', not 'built'" and sent the
# reader to look at Pages when the real problem was the token.
setup_repo 3
good_runs; good_pages; serve_ok; echo 1 > CASE_PAGES_ERR
run_case "pages 404 body reads as unreadable, not as a build" "drift" "could not be read" "not 'built'"
rm -f CASE_PAGES_ERR

setup_repo 3
good_runs; good_pages; serve_ok; echo 0 > CASE_PAGES_ERR
run_case "pages error body with a ZERO exit still refused" "drift" "could not be read" "not 'built'"
rm -f CASE_PAGES_ERR

setup_repo 3
good_runs; good_pages; serve_ok; echo 1 > CASE_RUNS_ERR
run_case "runs 404 body reads as unreadable, not as a run" "drift" "whether the monitor is running is unknown" "last finished"
rm -f CASE_RUNS_ERR

# Exit 1 is caught by the empty-RUNS check alone, so it says nothing about the jq
# predicate. Only a ZERO exit carrying an error body reaches that guard, and without this
# case the predicate could be widened back to `jq -e .` with nothing going red.
setup_repo 3
good_runs; good_pages; serve_ok; echo 0 > CASE_RUNS_ERR
run_case "runs error body with a ZERO exit still refused" "drift" "whether the monitor is running is unknown" "last finished"
rm -f CASE_RUNS_ERR

echo ""
echo "D1. curl itself produces nothing, which is not the same as curl reporting 000."
# A shim that exits without printing leaves the command substitution empty. Without the
# ${STATUS:-000} default that empty value reaches the numeric comparisons and falls
# through to "answered HTTP " with nothing after it. The guard has to be reachable by a
# case or it is not a guard, it is a comment.
setup_repo 3
good_runs; good_pages; serve_ok
mkdir -p "$NOCURL"
printf '#!/bin/sh\nexit 127\n' > "$NOCURL/curl"
chmod +x "$NOCURL/curl"
OLD_STUBBIN="$STUBBIN"; STUBBIN="$NOCURL:$STUBBIN"
run_case "curl produces no status at all" "drift" "never completed"
STUBBIN="$OLD_STUBBIN"

echo ""
echo "D2. unreachable. The server is stopped so the request genuinely never completes."
setup_repo 3
good_runs; good_pages; serve_ok
kill $SRV 2>/dev/null; sleep 1
run_case "domain unreachable is 000, not 000000" "drift" "never completed"

echo ""
echo "==================================================================="
echo "passed $PASS, failed $FAIL"
if [ "$FAIL" -gt 0 ]; then printf 'failed: %s\n' "${FAILED_CASES[*]}"; exit 1; fi
