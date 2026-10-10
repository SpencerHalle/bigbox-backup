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

case "$mode" in
  check)      exec "$RESTIC" snapshots --compact ;;   # read-only connectivity test
  backup)     ;;
  backup\ *)  LIMIT_UPLOAD_KIB=${mode#backup } ;;     # office can pass a limit
  *)          echo "unknown mode: $mode" >&2; exit 2 ;;
esac

# don`t snapshot the mirror while backup.sh is mid-rsync; wait for it, then let go
exec 9>/tmp/bigbox-backup.lock
flock -w 7200 9 || echo "warning: nightly backup still running after 2h, continuing" >&2
flock -u 9

start=$(date +%s)
limit=(); [ "$LIMIT_UPLOAD_KIB" -gt 0 ] 2>/dev/null && limit=(--limit-upload "$LIMIT_UPLOAD_KIB")

podman unshare "$RESTIC" backup --host bigbox --tag nightly "${limit[@]}" \
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
  /home/spencer/.config/systemd/user
rc=$?   # 0 ok, 3 = snapshot made but some files unreadable

end=$(date +%s)
printf "{\"ts\":%s,\"iso\":\"%s\",\"ok\":%s,\"rc\":%s,\"duration_s\":%s}\n" \
  "$end" "$(date -Is)" "$([ $rc -eq 0 ] && echo true || echo false)" "$rc" "$((end-start))" > "$STATUS"
exit $rc
