#!/bin/bash
# brain-sync.sh — two-way git sync of Hermes's knowledge/memory "brain"
# between this Railway volume ($HERMES_HOME, i.e. /data/.hermes) and a private
# GitHub repo (scandolo/brain).
#
# Direction 1 (cloud → GitHub): changes Hermes makes to its knowledge on the
#   volume are committed and pushed to origin/main.
# Direction 2 (GitHub → cloud): commits landed on origin/main from elsewhere
#   (e.g. Federico merging from his Mac) are pulled back into the volume.
#
# KNOWLEDGE ONLY. An allowlist .gitignore (written into the volume on init)
# tracks just the brain dirs and leaves everything else behind:
#   - secrets:        .env, auth.json, config.yaml*
#   - session memory: state.db*, sessions/        (deliberately excluded)
#   - junk:           caches, logs, bin/, home/, the wrapper, etc.
#
# Activated by start.sh ONLY when BRAIN_GIT_REMOTE and BRAIN_GIT_TOKEN are set,
# so the template still runs fine for anyone who hasn't configured sync.
#
# Usage:  brain-sync.sh [loop|once]   (default: loop)

BRAIN_DIR="${HERMES_HOME:-/data/.hermes}"
REMOTE="${BRAIN_GIT_REMOTE:-}"
TOKEN="${BRAIN_GIT_TOKEN:-}"
INTERVAL="${BRAIN_SYNC_INTERVAL:-600}"
GIT_NAME="${BRAIN_GIT_NAME:-Hermes}"
GIT_EMAIL="${BRAIN_GIT_EMAIL:-hermes@noreply.local}"
BRANCH="main"
MODE="${1:-loop}"
LOG="${BRAIN_DIR}/logs/brain-sync.log"

log() {
  mkdir -p "$(dirname "$LOG")" 2>/dev/null
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG"
}

if [ -z "$REMOTE" ] || [ -z "$TOKEN" ]; then
  log "BRAIN_GIT_REMOTE / BRAIN_GIT_TOKEN not set — brain sync disabled"
  exit 0
fi

# Authenticate via an HTTP header built at call time, so the token never lands
# in .git/config or the remote URL on the persistent volume. GitHub accepts a
# fine-grained PAT in the password position with any username.
AUTH_B64="$(printf 'x-access-token:%s' "$TOKEN" | base64 | tr -d '\n')"
git_auth() { git -C "$BRAIN_DIR" -c "http.extraheader=AUTHORIZATION: Basic ${AUTH_B64}" "$@"; }
git_plain() { git -C "$BRAIN_DIR" "$@"; }

write_meta() {
  # Allowlist: ignore the entire volume, then re-include only the brain.
  cat > "$BRAIN_DIR/.gitignore" <<'EOF'
# Ignore everything on the volume by default ...
/*
# ... then track ONLY these knowledge/memory paths.
!/.gitignore
!/.gitattributes
!/SOUL.md
!/about-me/
!/knowledge-vault/
!/memories/
!/notes/
!/plans/

# Never track transient lock / OS files inside the brain dirs.
*.lock
.DS_Store
EOF

  # Union-merge markdown: when cloud Hermes and the local Mac edit the same
  # file between syncs, keep BOTH sides rather than emitting conflict markers
  # (which Hermes would then read as content) or dropping one side. Occasional
  # duplication is visible and recoverable; lost knowledge is not.
  cat > "$BRAIN_DIR/.gitattributes" <<'EOF'
*.md merge=union
EOF
}

init_repo() {
  git config --global --add safe.directory "$BRAIN_DIR" 2>/dev/null
  if [ ! -d "$BRAIN_DIR/.git" ]; then
    log "initializing brain repo at $BRAIN_DIR"
    git_plain init -q -b "$BRANCH" 2>>"$LOG"
    git_plain remote add origin "$REMOTE" 2>>"$LOG"
  else
    git_plain remote set-url origin "$REMOTE" 2>/dev/null \
      || git_plain remote add origin "$REMOTE" 2>>"$LOG"
  fi
  git_plain config user.name "$GIT_NAME"
  git_plain config user.email "$GIT_EMAIL"
  git_plain symbolic-ref HEAD "refs/heads/$BRANCH" 2>/dev/null
  write_meta
}

commit_local() {
  git_plain add -A 2>>"$LOG"
  if ! git_plain diff --cached --quiet 2>/dev/null; then
    if git_plain commit -q -m "hermes: brain sync $(date -u +%Y-%m-%dT%H:%M:%SZ)" 2>>"$LOG"; then
      log "committed local brain changes"
    fi
  fi
}

sync_once() {
  # 1. Capture whatever Hermes changed on the volume.
  commit_local

  # 2. Fetch remote. May not exist yet on the very first push (empty repo).
  if ! git_auth fetch -q origin "$BRANCH" 2>>"$LOG"; then
    log "fetch: origin/$BRANCH not available yet (first run?)"
  fi

  # 3. Merge remote changes (e.g. from Federico's Mac) into the volume.
  if git_plain rev-parse -q --verify "origin/$BRANCH" >/dev/null 2>&1; then
    if git_plain rev-parse -q --verify HEAD >/dev/null 2>&1; then
      if ! git_plain merge --no-edit -q --allow-unrelated-histories "origin/$BRANCH" 2>>"$LOG"; then
        log "WARN merge conflict — aborting merge, keeping local for this cycle (review needed)"
        git_plain merge --abort 2>/dev/null
      fi
    else
      # Local has no commits yet — adopt the remote state wholesale.
      git_plain reset -q --hard "origin/$BRANCH" 2>>"$LOG"
    fi
  fi

  # 4. Push the integrated state back to GitHub.
  if ! git_auth push -q origin "$BRANCH" 2>>"$LOG"; then
    log "WARN push failed (will retry next cycle)"
  fi
}

init_repo

case "$MODE" in
  once)
    sync_once
    log "one-shot sync complete"
    ;;
  *)
    log "brain sync started (interval=${INTERVAL}s)"
    sync_once                 # immediate sync on boot so remote→volume lands fast
    while true; do
      sleep "$INTERVAL"
      sync_once
    done
    ;;
esac
