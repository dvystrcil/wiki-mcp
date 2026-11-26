#!/bin/sh
# The llm-wiki clone on the PVC stays shallow: CLONE_DEPTH commits, on every
# sync, not only at first clone. wiki-mcp reads files, never git history.
#
# `git clone --depth 50` alone did not do that. The PVC was cloned on
# 2026-05-24 when llm-wiki had 19 commits, so depth 50 copied everything and
# left no .git/shallow; every 30 s `git pull` since then has added history
# (209 commits on 2026-11-26). Even a clone that starts shallow grows without
# bound under plain pulls.
#
# Contract under test (the shipped scripts, extracted from the ConfigMap):
#   1. init.sh on an empty volume clones CLONE_DEPTH commits
#   2. init.sh on an existing FULL clone (the live PVC) cuts it to CLONE_DEPTH
#   3. sync.sh keeps a full clone at CLONE_DEPTH after pulling new commits,
#      and gc removes commits that fell out of the window
#   4. sync.sh still commits + pushes a local write (rebase inside the window)
#
# Offline: a local bare repo (file:// URL; --depth is ignored for plain local
# paths) stands in for GitHub; apk and get-token.sh are stubbed.
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
export GIT_REMOTE_URL="file://$WORK/origin.git" CLONE_DEPTH=5

# origin with $1 commits; the first one's sha is saved in $WORK/first
setup_origin() {
  rm -rf "$WORK/origin.git" "$WORK/seed" "$WORK/data"
  git init -q --bare -b main "$WORK/origin.git"
  git clone -q "$WORK/origin.git" "$WORK/seed" 2>/dev/null
  ( cd "$WORK/seed" && git config user.email t@t && git config user.name t
    i=1; while [ "$i" -le "$1" ]; do echo "$i" > f; git add f; git commit -qm "c$i"; i=$((i+1)); done
    git rev-list --max-parents=0 HEAD > "$WORK/first"
    git push -q origin main )
}
push_remote_commit() {
  ( cd "$WORK/seed" && echo "$1" > g && git add g && git commit -qm "$1" && git push -q origin main )
}
depth() { git -C "$WORK/data" rev-list --count HEAD; }
origin_head() { git -C "$WORK/origin.git" rev-parse main; }
run_sync() {
  WIKI_ROOT="$WORK/data" SYNC_INTERVAL_SECONDS=0 SYNC_MAX_LOOPS=1 GC_EVERY_LOOPS=1 \
    sh "$WORK/sync.sh" > "$WORK/log" 2>&1 || { cat "$WORK/log"; fail "sync.sh exited non-zero"; }
}

# --- 1. empty volume: shallow clone ------------------------------------------
setup_origin 12
mkdir -p "$WORK/data"
WIKI_ROOT="$WORK/data" sh "$WORK/init.sh" > "$WORK/log" 2>&1 || { cat "$WORK/log"; fail "init.sh failed on an empty volume"; }
[ "$(depth)" -eq 5 ] || fail "fresh clone has $(depth) commits, want 5"
[ -f "$WORK/data/.git/shallow" ] || fail "fresh clone is not shallow"
echo "ok   init.sh: empty volume -> $(depth)-commit shallow clone"

# --- 2. existing full clone (the live PVC) is cut on restart -----------------
setup_origin 12
git clone -q "$GIT_REMOTE_URL" "$WORK/data"
[ "$(depth)" -eq 12 ] || fail "setup: full clone has $(depth) commits"
push_remote_commit r1
WIKI_ROOT="$WORK/data" sh "$WORK/init.sh" > "$WORK/log" 2>&1 || { cat "$WORK/log"; fail "init.sh failed on an existing clone"; }
[ "$(git -C "$WORK/data" rev-parse HEAD)" = "$(origin_head)" ] || { cat "$WORK/log"; fail "init.sh did not fast-forward"; }
[ "$(depth)" -le 5 ] || fail "init.sh left $(depth) commits of history, want <= 5"
echo "ok   init.sh: full clone -> $(depth) commits after fast-forward"

# --- 3. sync keeps a full clone shallow, gc drops old commits ----------------
setup_origin 12
git clone -q "$GIT_REMOTE_URL" "$WORK/data"
( cd "$WORK/data" && git config user.email t@t && git config user.name t
  # A reflog entry for an old commit, as months of pulls leave on the PVC;
  # gc keeps anything a reflog names unless the entry is expired.
  git checkout -q "$(cat "$WORK/first")" && git checkout -q main )
push_remote_commit r1
run_sync
[ "$(git -C "$WORK/data" rev-parse HEAD)" = "$(origin_head)" ] || { cat "$WORK/log"; fail "sync did not land the remote commit"; }
[ "$(depth)" -le 5 ] || { cat "$WORK/log"; fail "sync left $(depth) commits of history, want <= 5"; }
if git -C "$WORK/data" cat-file -e "$(cat "$WORK/first")" 2>/dev/null; then
  fail "first commit still on disk after gc; history was not dropped"
fi
echo "ok   sync.sh: full clone -> $(depth) commits, out-of-window objects pruned"

# --- 4. local write still commits, rebases and pushes ------------------------
push_remote_commit r2
echo local > "$WORK/data/local.md"
run_sync
git -C "$WORK/origin.git" cat-file -e main:local.md 2>/dev/null || { cat "$WORK/log"; fail "local write was not pushed"; }
git -C "$WORK/origin.git" cat-file -e main:g 2>/dev/null || fail "remote commit lost by the rebase"
[ "$(git -C "$WORK/data" rev-parse HEAD)" = "$(origin_head)" ] || { cat "$WORK/log"; fail "local and origin differ after push"; }
[ "$(depth)" -le 6 ] || fail "after a local commit: $(depth) commits, want <= 6"
echo "ok   sync.sh: local write committed, rebased onto the new remote commit, pushed"
echo "PASS: llm-wiki clone stays shallow at CLONE_DEPTH"
