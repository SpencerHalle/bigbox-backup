#!/usr/bin/env bash
# Nightly local backup (00:30, ahead of the 02:00 offsite pull — see offsite.sh): nextcloud + immich + recipe-app  ->  /media/backup
#
# Incremental — rsync only moves changed files. This is a MIRROR, not history
# (that's what the planned Borg repo on `office` is for); the compressed DB
# dumps keep KEEP_DB_DAYS of history under db-history/.
#
# Scheduled by bigbox-backup.timer. Writes /media/backup/.backup-status.json
# on every exit; bigbox-monitor reads it and publishes to Home Assistant, so a
# silent failure shows up as sensor.bigbox_backup = failed/stale + a phone alert.
#
# No secrets live here: the MariaDB password is read from the container's own
# env, Postgres uses local trust auth.
set -uo pipefail

DEST=/media/backup
STATUS="$DEST/.backup-status.json"
LOCK=/tmp/bigbox-backup.lock
MAX_DELETE=10000          # circuit breaker: a sync that wants to delete more aborts
KEEP_DB_DAYS=7

exec 9>"$LOCK"
if ! flock -n 9; then
  echo "another backup run holds the lock; exiting" >&2
  exit 0
fi

start=$(date +%s)
declare -A step           # step -> "ok" | "FAIL: reason"
ok=1
nc_maint=0                # 1 while nextcloud is in maintenance mode

log()  { echo "$(date +%H:%M:%S) $*"; }
fail() { step["$1"]="FAIL: $2"; ok=0; log "!!! $1 FAILED: $2"; }

finish() {
  # runs on ANY exit (trap) — always leaves maintenance mode off + status written
  if [ "$nc_maint" = 1 ]; then
    podman exec -u www-data nextcloud php occ maintenance:mode --off >/dev/null 2>&1 \
      && log "nextcloud: maintenance mode off (cleanup)"
  fi
  local end steps_json="" first=1 k free
  end=$(date +%s)
  for k in "${!step[@]}"; do
    [ $first -eq 1 ] || steps_json+=","
    steps_json+="\"$k\":\"${step[$k]}\""; first=0
  done
  free=$(df -B1 --output=avail "$DEST" 2>/dev/null | tail -1 | tr -d ' ')
  printf '{"ts":%s,"iso":"%s","ok":%s,"duration_s":%s,"steps":{%s},"dest_free_bytes":%s}\n' \
    "$end" "$(date -Is)" "$([ $ok -eq 1 ] && echo true || echo false)" \
    "$((end - start))" "$steps_json" "${free:-0}" > "$STATUS"
  log "status written: ok=$ok duration=$((end - start))s"
}
trap finish EXIT

log "=== backup start ==="
mkdir -p "$DEST/nextcloud" "$DEST/immich" "$DEST/recipes" "$DEST/db-history"

# ---------------------------------------------------------------- Nextcloud
NC_SRC=/media/storage/nextcloud_data
if podman unshare sh -c "test -r '$NC_SRC/config/config.php'"; then
  if podman exec -u www-data nextcloud php occ maintenance:mode --on >/dev/null 2>&1; then
    nc_maint=1; log "nextcloud: maintenance mode on"
  else
    log "nextcloud: WARN could not enable maintenance mode (continuing)"
  fi

  log "nextcloud: db dump"
  if podman exec nextcloud-db sh -c \
       'mariadb-dump -u root -p"$MYSQL_ROOT_PASSWORD" --single-transaction --quick nextcloud' \
       | gzip > "$DEST/nextcloud/nextcloud-db.sql.gz.tmp"; then
    mv "$DEST/nextcloud/nextcloud-db.sql.gz.tmp" "$DEST/nextcloud/nextcloud-db.sql.gz"
    cp "$DEST/nextcloud/nextcloud-db.sql.gz" "$DEST/db-history/nextcloud-db.$(date +%F).sql.gz"
    step[nextcloud_db]=ok
    log "nextcloud: db dump ok ($(du -h "$DEST/nextcloud/nextcloud-db.sql.gz" | cut -f1))"
  else
    rm -f "$DEST/nextcloud/nextcloud-db.sql.gz.tmp"
    fail nextcloud_db "mariadb-dump pipeline non-zero"
  fi

  # podman unshare: run rsync inside the container's rootless UID namespace, else
  # the whole data/ tree is Permission denied (owned by a remapped subuid).
  log "nextcloud: file sync (podman unshare, delta)"
  if podman unshare rsync -a --delete --max-delete=$MAX_DELETE \
       --exclude=files_trashbin --exclude=uploads \
       "$NC_SRC/" "$DEST/nextcloud/files/"; then
    step[nextcloud_files]=ok; log "nextcloud: file sync ok"
  else
    fail nextcloud_files "rsync exit $?"
  fi

  podman exec -u www-data nextcloud php occ maintenance:mode --off >/dev/null 2>&1 \
    && { nc_maint=0; log "nextcloud: maintenance mode off"; }
else
  fail nextcloud_db "source unreadable — skipped"
  fail nextcloud_files "$NC_SRC/config/config.php not readable — skipped (won't --delete against an empty source)"
fi

# ---------------------------------------------------------------- Immich
IM_SRC=/media/storage/photos
log "immich: db dump"
if podman exec immich-db sh -c 'pg_dump -U postgres immich' \
     | gzip > "$DEST/immich/immich-db.sql.gz.tmp"; then
  mv "$DEST/immich/immich-db.sql.gz.tmp" "$DEST/immich/immich-db.sql.gz"
  cp "$DEST/immich/immich-db.sql.gz" "$DEST/db-history/immich-db.$(date +%F).sql.gz"
  step[immich_db]=ok
  log "immich: db dump ok ($(du -h "$DEST/immich/immich-db.sql.gz" | cut -f1))"
else
  rm -f "$DEST/immich/immich-db.sql.gz.tmp"
  fail immich_db "pg_dump pipeline non-zero"
fi

if [ -d "$IM_SRC" ] && [ -n "$(ls -A "$IM_SRC" 2>/dev/null)" ]; then
  log "immich: photo sync (delta)"
  if rsync -a --delete --max-delete=$MAX_DELETE "$IM_SRC/" "$DEST/immich/photos/"; then
    step[immich_files]=ok; log "immich: photo sync ok"
  else
    fail immich_files "rsync exit $?"
  fi
else
  fail immich_files "source $IM_SRC empty/missing — skipped"
fi

# ---------------------------------------------------------------- recipe-app
RC_SRC=/home/spencer/homelab/recipes
if [ -d "$RC_SRC/data" ]; then
  log "recipes: sync data + secrets (delta)"
  r=0
  rsync -a --delete "$RC_SRC/data/"    "$DEST/recipes/data/"    || r=$?
  rsync -a --delete "$RC_SRC/secrets/" "$DEST/recipes/secrets/" || r=$?
  if [ $r -eq 0 ]; then step[recipes]=ok; log "recipes: sync ok"
  else fail recipes "rsync exit $r"; fi
else
  fail recipes "source $RC_SRC/data missing — skipped"
fi

# ---------------------------------------------------------------- prune
find "$DEST/db-history" -name '*.sql.gz' -mtime +$KEEP_DB_DAYS -delete 2>/dev/null || true

log "=== backup end (ok=$ok) ==="
[ $ok -eq 1 ]
