#!/bin/bash
# Uploads finished camera recordings to S3, then removes them locally.

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

SRC="$HOME/cam/recordings/cam1"
DEST="s3cam:cam1-recording/cam1"
LOG="$HOME/cam/upload.log"
LOCK="/tmp/cam-upload.lock"

# Skip if a previous run is still going
if ! mkdir "$LOCK" 2>/dev/null; then
  echo "=== $(date '+%F %T') skipped (already running) ===" >> "$LOG"
  exit 0
fi
trap 'rmdir "$LOCK"' EXIT

# Keep the log from growing forever (~5 MB cap)
if [ -f "$LOG" ] && [ "$(stat -f%z "$LOG")" -gt 5242880 ]; then
  mv "$LOG" "$LOG.old"
fi

echo "=== $(date '+%F %T') start ===" >> "$LOG"

# --min-age 15m skips the segment MediaMTX is still writing (10 min segments)
rclone move "$SRC" "$DEST" \
  --include "*.mp4" \
  --min-age 15m \
  --s3-no-head \
  --s3-no-check-bucket \
  --transfers 2 \
  --log-level INFO >> "$LOG" 2>&1
STATUS=$?

echo "=== done (exit $STATUS) ===" >> "$LOG"
exit $STATUS