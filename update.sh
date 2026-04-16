#!/usr/bin/env bash
set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────
HEADWAY_REPO="/Users/yiweigao/headway"
DEPLOY_DIR="/tmp/calendar-audit-deploy"
SCREENSHOT_SCRIPT="/tmp/calendar-audit-screenshots/capture-cropped.js"
SCREENSHOT_DIR="/tmp/calendar-audit-screenshots"
LAST_SYNC_FILE="$DEPLOY_DIR/last-sync.txt"
CHANGELOG_FILE="$DEPLOY_DIR/changelog.json"

# Calendar-related paths to watch for changes.
CALENDAR_PATHS=(
  "web/apps/sigmund/app/legacy/views/Calendar/"
)

# ── Helpers ──────────────────────────────────────────────────────────────────
log() { printf '\033[1;34m▸\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m▸\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m▸\033[0m %s\n' "$*" >&2; }

# ── Preflight checks ────────────────────────────────────────────────────────
if [[ ! -d "$HEADWAY_REPO/.git" ]]; then
  err "Headway repo not found at $HEADWAY_REPO"; exit 1
fi

if [[ ! -f "$LAST_SYNC_FILE" ]]; then
  err "last-sync.txt not found at $LAST_SYNC_FILE"; exit 1
fi

if [[ ! -f "$CHANGELOG_FILE" ]]; then
  log "Creating empty changelog.json"
  echo '[]' > "$CHANGELOG_FILE"
fi

# ── Step 1: Find new commits touching calendar files ─────────────────────────
LAST_HASH=$(tr -d '[:space:]' < "$LAST_SYNC_FILE")
log "Last synced commit: $LAST_HASH"

cd "$HEADWAY_REPO"

# Make sure we have the latest main.
CURRENT_MAIN=$(git rev-parse main)
log "Current main HEAD:  $CURRENT_MAIN"

if [[ "$LAST_HASH" == "$CURRENT_MAIN" ]]; then
  log "Already up to date. Nothing to do."
  exit 0
fi

# Build the path arguments for git log.
PATH_ARGS=()
for p in "${CALENDAR_PATHS[@]}"; do
  PATH_ARGS+=("$p")
done

# Collect commits between last sync and current main that touch calendar paths.
# Format: hash||subject||author||date
COMMITS=$(git log --pretty=format:"%H||%s||%an||%aI" "$LAST_HASH".."$CURRENT_MAIN" -- "${PATH_ARGS[@]}" 2>/dev/null || true)

if [[ -z "$COMMITS" ]]; then
  log "No calendar-related commits since last sync."
  # Still update last-sync.txt so we don't re-scan this range.
  echo "$CURRENT_MAIN" > "$LAST_SYNC_FILE"
  cd "$DEPLOY_DIR"
  git add last-sync.txt
  if git diff --cached --quiet; then
    log "Nothing to commit."
  else
    git commit -m "Update last-sync.txt to $CURRENT_MAIN (no calendar changes)"
    git push origin main
  fi
  exit 0
fi

COMMIT_COUNT=$(echo "$COMMITS" | wc -l | tr -d ' ')
log "Found $COMMIT_COUNT calendar-related commit(s)."

# ── Step 2: Update changelog.json ────────────────────────────────────────────
log "Updating changelog.json..."

# Read existing changelog.
EXISTING_CHANGELOG=$(cat "$CHANGELOG_FILE")

# Build new entries as a JSON array.
NEW_ENTRIES="[]"
while IFS='||' read -r hash _ subject _ author _ date _; do
  # Skip empty lines.
  [[ -z "$hash" ]] && continue

  # Try to extract PR number from subject (e.g., "(#12345)" at end).
  pr_number=""
  pr_url=""
  if [[ "$subject" =~ \(#([0-9]+)\) ]]; then
    pr_number="${BASH_REMATCH[1]}"
    pr_url="https://github.com/headway/headway/pull/$pr_number"
  fi

  # Build JSON entry using python for safe escaping.
  entry=$(python3 -c "
import json, sys
print(json.dumps({
    'hash': sys.argv[1],
    'title': sys.argv[2],
    'author': sys.argv[3],
    'date': sys.argv[4],
    'pr_number': sys.argv[5] if sys.argv[5] else None,
    'pr_url': sys.argv[6] if sys.argv[6] else None,
}))
" "$hash" "$subject" "$author" "$date" "$pr_number" "$pr_url")

  NEW_ENTRIES=$(python3 -c "
import json, sys
entries = json.loads(sys.argv[1])
entries.append(json.loads(sys.argv[2]))
print(json.dumps(entries))
" "$NEW_ENTRIES" "$entry")

  log "  + $subject ($author)"
done <<< "$COMMITS"

# Merge new entries into existing changelog (newest first).
python3 -c "
import json, sys
existing = json.loads(sys.argv[1])
new = json.loads(sys.argv[2])
# Deduplicate by hash.
seen = {e['hash'] for e in existing}
for entry in new:
    if entry['hash'] not in seen:
        existing.insert(0, entry)
        seen.add(entry['hash'])
print(json.dumps(existing, indent=2))
" "$EXISTING_CHANGELOG" "$NEW_ENTRIES" > "$CHANGELOG_FILE"

log "Changelog updated with $(echo "$NEW_ENTRIES" | python3 -c 'import json,sys; print(len(json.loads(sys.stdin.read())))') new entries."

# ── Step 3: Re-capture screenshots ──────────────────────────────────────────
if [[ -f "$SCREENSHOT_SCRIPT" ]]; then
  log "Running screenshot capture..."
  if node "$SCREENSHOT_SCRIPT"; then
    log "Screenshots captured successfully."
    # Copy screenshots to deploy dir.
    for f in "$SCREENSHOT_DIR"/tab-*.png; do
      if [[ -f "$f" ]]; then
        cp "$f" "$DEPLOY_DIR/"
        log "  Copied $(basename "$f")"
      fi
    done
  else
    warn "Screenshot capture failed. Continuing with changelog update only."
  fi
else
  warn "Screenshot script not found at $SCREENSHOT_SCRIPT. Skipping capture."
fi

# ── Step 4: Update last-sync.txt ────────────────────────────────────────────
echo "$CURRENT_MAIN" > "$LAST_SYNC_FILE"
log "Updated last-sync.txt to $CURRENT_MAIN"

# ── Step 5: Commit and push ─────────────────────────────────────────────────
cd "$DEPLOY_DIR"
git add -A

if git diff --cached --quiet; then
  log "No changes to commit."
  exit 0
fi

COMMIT_MSG="Update calendar audit: $COMMIT_COUNT new commit(s)

Calendar commits synced:
$(echo "$COMMITS" | while IFS='||' read -r hash _ subject _rest; do
  echo "  - ${subject} (${hash:0:7})"
done)

Synced to: $CURRENT_MAIN"

git commit -m "$COMMIT_MSG"
git push origin main

log "Done! Changes committed and pushed."
