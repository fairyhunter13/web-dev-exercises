#!/usr/bin/env bash
#
# Keep a current local copy of the record. Runs daily from a systemd user timer,
# and by hand.
#
# This is the backup. The archive teardown.sh writes in CI is a gate - it proves
# the state could be read and decrypted before anything was destroyed - and it
# dies with the runner. Nothing is uploaded and nothing is committed: an
# encrypted blob in a public repository is still a published artifact whose
# name, size and cadence are readable, and it would have no reader other than
# the person who already has the file.
#
#   ./deliver.sh              write today's archive if there is not one
#   ./deliver.sh --force      write one regardless
#   ./deliver.sh --install    install and start the systemd user timer
#
# Idempotent by date, so a catch-up run after the laptop was off does one
# archive rather than one per missed day.
#
# Refuses to run without the private key. An archive that cannot be decrypted is
# not a backup, it is a file, and the difference only shows up on the day it
# matters. verify_archive in archive.sh checks structure without a key and
# contents with one; this insists on the second.
set -euo pipefail
set +x

cd "$(dirname "$0")"

OUT_DIR="${OUT_DIR:-$HOME/backups/chat-demo}"
KEY="${AGE_KEY_FILE:-$HOME/.config/chat-demo/archive-key.txt}"
KEEP=14
FORCE=""

case "${1:-}" in
  --force)   FORCE=1 ;;
  --install) INSTALL=1 ;;
  "")        ;;
  *) echo "unknown argument: $1" >&2; exit 2 ;;
esac

if [[ -n "${INSTALL:-}" ]]; then
  UNIT_DIR="$HOME/.config/systemd/user"
  mkdir -p "$UNIT_DIR"
  SELF="$(cd "$(dirname "$0")" && pwd)/deliver.sh"

  cat > "$UNIT_DIR/chat-demo-archive.service" <<EOF
[Unit]
Description=Archive the demo stack's records locally

[Service]
Type=oneshot
ExecStart=$SELF
EOF

  # Persistent=true is the whole reason this is a timer rather than a cron
  # entry: the laptop is not on at 04:00 every day, and without it a missed
  # window is simply skipped. RandomizedDelaySec spreads it off the minute.
  cat > "$UNIT_DIR/chat-demo-archive.timer" <<EOF
[Unit]
Description=Daily local archive of the demo stack's records

[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=30m

[Install]
WantedBy=timers.target
EOF

  systemctl --user daemon-reload
  systemctl --user enable --now chat-demo-archive.timer
  systemctl --user list-timers chat-demo-archive.timer --no-pager
  exit 0
fi

if [[ ! -r "$KEY" ]]; then
  echo "no private key at the configured path; refusing to write an archive that cannot be read back" >&2
  exit 1
fi

if [[ -f .teardown-complete ]]; then
  echo "already torn down on $(head -1 .teardown-complete); nothing left to archive"
  exit 0
fi

STAMP="$(date -u +%Y-%m-%d)"
if [[ -z "$FORCE" && -s "$OUT_DIR/$STAMP.age" ]]; then
  echo "today's archive already exists; nothing to do"
  exit 0
fi

# Records only. The build artifacts are 8.7 MB of Go binary rebuildable from the
# pinned commit; the records are 12 KB and are not reproducible at all. The
# binary is captured once, at teardown, by the full archive.
# Exported rather than prefixed, so the verify below reads back with the same
# key the write was checked against. A verify that silently fell through to the
# default path would report success about a different file's key.
export AGE_KEY_FILE="$KEY"
./archive.sh --records-only --out "$OUT_DIR" >/dev/null
./archive.sh --verify "$OUT_DIR/$STAMP.age"

# Pruning by count, not by age: the point of a floor is that a run of bad
# archives cannot leave zero good ones behind.
mapfile -t old < <(ls -1 "$OUT_DIR"/*.age 2>/dev/null | sort | head -n -"$KEEP")
if [[ "${#old[@]}" -gt 0 ]]; then
  rm -f -- "${old[@]}"
  echo "pruned ${#old[@]} archive(s), keeping the most recent $KEEP"
fi
