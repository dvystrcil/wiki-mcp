#!/bin/sh
# The git-sync sidecar must not wedge on a stale git lock, and must not fail
# silently forever.
#
# 2026-09-06 03:12 a git process on the PVC died holding .git/ORIG_HEAD.lock.
# Every `git pull` after that failed ("cannot lock ref 'ORIG_HEAD'"), sync.sh
# logged "pull failed -- will retry" and `continue`d -- skipping the push too --
# for a month. wiki-mcp served llm-wiki frozen at #32; any wiki_write in that
# window would have been committed on the PVC and never pushed. Nothing alerted.
#
# Contract under test (the shipped sync.sh, extracted from the ConfigMap):
#   1. a lock older than STALE_LOCK_MINUTES with no git process running is
#      removed, and the pull lands
#   2. a FRESH lock is never removed (a live git may own it)
#   3. after MAX_PULL_FAILS consecutive failed pulls the sidecar EXITS non-zero,
#      so the container restarts and the restart count / alerts show it
#
# Offline: a local bare repo stands in for GitHub; apk and get-token.sh are
# stubbed.
set -eu

REPO_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

python3 - "${REPO_ROOT}/base/git-sync-script.yaml" "$WORK" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))["data"]
for k in ("sync.sh", "init.sh"):
    assert k in d, k
    open(f"{sys.argv[2]}/{k}", "w").write(d[k])
PY

mkdir -p "$WORK/bin" "$WORK/scripts"
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/apk"; chmod +x "$WORK/bin/apk"
printf '#!/bin/sh\nprintf tok\n' > "$WORK/scripts/get-token.sh"
export PATH="$WORK/bin:$PATH" SCRIPTS_DIR="$WORK/scripts"

setup() {   # $1 = lock age: "old" or "fresh"
  rm -rf "$WORK/origin.git" "$WORK/seed" "$WORK/data"
  git init -q --bare -b main "$WORK/origin.git"
  git clone -q "$WORK/origin.git" "$WORK/seed" 2>/dev/null
  ( cd "$WORK/seed" && git config user.email t@t && git config user.name t \
    && echo one > f && git add f && git commit -qm one && git push -q origin main )
  git clone -q "$WORK/origin.git" "$WORK/data"
  ( cd "$WORK/seed" && echo two > f && git commit -qam two && git push -q origin main )
  : > "$WORK/data/.git/ORIG_HEAD.lock"
  [ "$1" = old ] && touch -d '1 day ago' "$WORK/data/.git/ORIG_HEAD.lock"
  true
}
origin_head() { git -C "$WORK/origin.git" rev-parse main; }

# --- 1. stale lock: cleared, pull lands ------------------------------------
setup old
WIKI_ROOT="$WORK/data" GIT_REMOTE_URL="$WORK/origin.git" SYNC_INTERVAL_SECONDS=0 SYNC_MAX_LOOPS=1 \
  sh "$WORK/sync.sh" > "$WORK/log1" 2>&1 || { cat "$WORK/log1"; fail "sync.sh exited non-zero on a clearable lock"; }
[ ! -e "$WORK/data/.git/ORIG_HEAD.lock" ] || fail "stale lock not removed"
[ "$(git -C "$WORK/data" rev-parse HEAD)" = "$(origin_head)" ] || { cat "$WORK/log1"; fail "pull did not land after clearing the lock"; }
grep -q "removed stale" "$WORK/log1" || fail "lock removal not logged"
echo "ok   stale lock removed, pull landed"

# --- 2+3. fresh lock: kept; repeated failures exit non-zero -----------------
setup fresh
set +e
WIKI_ROOT="$WORK/data" GIT_REMOTE_URL="$WORK/origin.git" SYNC_INTERVAL_SECONDS=0 SYNC_MAX_LOOPS=10 MAX_PULL_FAILS=3 \
  sh "$WORK/sync.sh" > "$WORK/log2" 2>&1
rc=$?
set -e
[ -e "$WORK/data/.git/ORIG_HEAD.lock" ] || fail "a FRESH lock was removed (a live git could own it)"
[ "$rc" -ne 0 ] || { cat "$WORK/log2"; fail "3 consecutive pull failures did not exit non-zero"; }
grep -q "consecutive pull failures" "$WORK/log2" || fail "exit reason not logged"
echo "ok   fresh lock kept; repeated pull failures exit non-zero (rc=$rc)"

# --- init.sh clears a stale lock too ----------------------------------------
setup old
WIKI_ROOT="$WORK/data" GIT_REMOTE_URL="$WORK/origin.git" sh "$WORK/init.sh" > "$WORK/log3" 2>&1 || true
[ "$(git -C "$WORK/data" rev-parse HEAD)" = "$(origin_head)" ] || { cat "$WORK/log3"; fail "init.sh did not fast-forward past a stale lock"; }
echo "ok   init.sh fast-forwards past a stale lock"
echo "PASS: git-sync survives a stale lock and fails loudly"
