#!/usr/bin/env bash
# Offsite backup: bigbox -> restic repo on `office` (separate site).
#
# NOT run by a timer here. office drives it: its timer SSHes in with a key that
# authorized_keys pins to this script, opens a reverse tunnel to office`s
# rest-server (bigbox 127.0.0.1:18000 -> office 127.0.0.1:8000) and pipes the
# repo password on stdin, so the password never lives on bigbox.
#
# rest-server runs --append-only: this box can ADD snapshots but cannot delete
# or rewrite them, so ransomware here can`t wipe the offsite history. Pruning
# happens on office, locally.
#
# Source = the /media/backup mirror that backup.sh refreshes nightly (consistent
# DB dumps + files), plus quadlets/configs. Run under `podman unshare` because
# nextcloud/immich files are owned by remapped subuids.
set -uo pipefail

REPO=rest:http://127.0.0.1:18000/restic/
RESTIC=/home/spencer/.local/bin/restic
STATUS=/media/backup/.offsite-status.json
LIMIT_UPLOAD_KIB=${LIMIT_UPLOAD_KIB:-0}   # 0 = unlimited

mode=${SSH_ORIGINAL_COMMAND:-backup}
IFS= read -r RESTIC_PASSWORD || { echo "no password on stdin" >&2; exit 2; }
export RESTIC_PASSWORD RESTIC_REPOSITORY=$REPO

# mode: "check" | "backup [LIMIT_UPLOAD_KIB [OFFICE_FREE_BYTES]]"  (office sends the args)
read -r -a args <<< "$mode"
case "${args[0]:-}" in
  check)  exec "$RESTIC" snapshots --compact ;;   # read-only connectivity test
  backup) LIMIT_UPLOAD_KIB=${args[1]:-$LIMIT_UPLOAD_KIB}; OFFICE_FREE=${args[2]:-} ;;
  *)      echo "unknown mode: $mode" >&2; exit 2 ;;
esac
STATUS_PY=/home/spencer/homelab/backup/offsite_status.py

# don`t snapshot the mirror while backup.sh is mid-rsync; wait for it, then let go
exec 9>/tmp/bigbox-backup.lock
flock -w 7200 9 || echo "warning: nightly backup still running after 2h, continuing" >&2
flock -u 9

limit=(); [ "$LIMIT_UPLOAD_KIB" -gt 0 ] 2>/dev/null && limit=(--limit-upload "$LIMIT_UPLOAD_KIB")

podman unshare "$RESTIC" backup --json --host bigbox --tag nightly "${limit[@]}" \
  --exclude /media/backup/lost+found \
  --exclude /media/backup/db-history \
  --exclude "/home/spencer/homelab/podman/*/db" \
  --exclude /home/spencer/homelab/podman/jellyfin \
  --exclude /home/spencer/homelab/podman/spencer_smp \
  --exclude /home/spencer/homelab/podman/mc-backup.tar.gz \
  --exclude /home/spencer/homelab/podman/ollama \
  --exclude /home/spencer/homelab/podman/comfyui \
  --exclude /home/spencer/homelab/podman/open-webui \
  --exclude /home/spencer/homelab/podman/audiobookshelf \
  --exclude /home/spencer/homelab/podman/romm \
  /media/backup \
  /home/spencer/homelab \
  /home/spencer/.config/containers/systemd \
  /home/spencer/.config/systemd/user \
  | "$STATUS_PY" "$STATUS" "${OFFICE_FREE:-}"
rc=${PIPESTATUS[0]}   # 0 ok, 3 = snapshot made but some files unreadable

# snapshot count + repo size for the dashboard (reads are allowed in append-only mode)
snaps=$("$RESTIC" snapshots --json --host bigbox 2>/dev/null | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null)
repo=$("$RESTIC" stats --json --mode raw-data 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin)[\"total_size\"])" 2>/dev/null)
"$STATUS_PY" "$STATUS" --finish "$rc" "${snaps:-}" "${repo:-}"
exit $rc
