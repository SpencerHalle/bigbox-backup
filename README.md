# bigbox-backup

Nightly incremental local backup of the three services that hold real data —
**Nextcloud**, **Immich**, **recipe-app** — to the dedicated 1 TB drive at
`/media/backup` (Laptop A's old HDD, ext4, `LABEL=bigbox_backup`).

This is a **mirror + short DB history**, not a versioned archive. It protects
against a single-disk failure on `tank` or a bad container upgrade. Whole-machine
loss (fire, theft) is covered by the planned Borg repo on `office` — not this.

## Pieces

| File | What |
|---|---|
| `backup.sh` | the job — DB dumps + `rsync` deltas, writes `.backup-status.json` |
| `bigbox-backup.service` / `.timer` | systemd **user** units — nightly ~03:30, `Persistent=true` |
| `setup.sh` | install/refresh the timer (re-run after editing units) |

## What it does each run

1. **Nextcloud** — `occ maintenance:mode --on`, `mariadb-dump --single-transaction`
   (gzipped), then `rsync -a --delete` of `/media/storage/nextcloud_data` via
   **`podman unshare`** (the data dir is owned by a remapped subuid — a plain
   rsync silently gets Permission denied on all of it), excluding
   `files_trashbin/` and `uploads/`. Maintenance mode off. Incremental runs are
   minutes.
2. **Immich** — `pg_dump` (gzipped) + `rsync -a --delete` of `/media/storage/photos`.
   No downtime (pg_dump is an MVCC snapshot).
3. **recipe-app** — `rsync -a --delete` of `~/homelab/recipes/{data,secrets}`.
4. Prune `db-history/*.sql.gz` older than 7 days.

`--max-delete=10000` on every `--delete` sync: if a run wants to delete more than
that (e.g. a source went unreadable), it aborts that sync and reports failure
instead of wiping the mirror.

No secrets in this repo: the MariaDB password is read from the container's own
env, Postgres uses local trust auth.

## Layout on the drive

```
/media/backup/
  nextcloud/nextcloud-db.sql.gz      immich/immich-db.sql.gz
  nextcloud/files/                   immich/photos/
  recipes/data/  recipes/secrets/
  db-history/{nextcloud,immich}-db.YYYY-MM-DD.sql.gz   (7 days)
  .backup-status.json                (ts, ok, per-step results, free space)
  README.md                          (restore steps)
```

## Monitoring

`backup.sh` writes `.backup-status.json` on every exit. `bigbox-monitor`
(`~/homelab/monitor/`) reads it each minute and publishes:

- `sensor.bigbox_backup` — `ok` / `failed` / `stale` (ok but >30 h old) / `unknown`
- `sensor.bigbox_backup_age_hours`

HA automation **`bigbox: nightly backup failed or stale`** sends a phone alert
when that sensor sits at `failed`/`stale` for 10 min.

## Operate

```bash
systemctl --user list-timers bigbox-backup.timer --no-pager
systemctl --user start bigbox-backup.service      # run now
journalctl --user -u bigbox-backup -n 60 --no-pager
cat /media/backup/.backup-status.json | python3 -m json.tool
```

## Restore

See `/media/backup/README.md` on the drive (written by the first full backup):
maintenance-mode + `mysql < dump` + copy `files/` back + `occ files:scan --all`
for Nextcloud; `psql < dump` + copy `photos/` back for Immich; copy
`data/`+`secrets/` back for recipe-app.
