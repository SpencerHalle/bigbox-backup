#!/usr/bin/env python3
"""Turn `restic backup --json` output (stdin) into /media/backup/.offsite-status.json.

Written every ~30s while running (so HA can show progress + ETA during the long
first upload) and once at the end. Keeps last_success_* across runs so a failed
night doesn`t hide how old the newest good offsite snapshot is.
Usage: restic backup --json ... | offsite_status.py STATUS_FILE OFFICE_FREE_BYTES
Final result is set separately with:  offsite_status.py STATUS_FILE --finish RC [SNAPSHOTS] [REPO_BYTES]
"""
import json, os, sys, time
from datetime import datetime

path = sys.argv[1]

def load():
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}

def save(st):
    st["ts"] = int(time.time())
    st["iso"] = datetime.now().astimezone().isoformat(timespec="seconds")
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(st, f)
    os.replace(tmp, path)

if len(sys.argv) > 2 and sys.argv[2] == "--finish":
    st = load()
    rc = int(sys.argv[3])
    st.update(running=False, ok=(rc == 0), rc=rc,
              duration_s=int(time.time()) - st.get("started_ts", int(time.time())))
    if len(sys.argv) > 4 and sys.argv[4].isdigit(): st["snapshots"] = int(sys.argv[4])
    if len(sys.argv) > 5 and sys.argv[5].isdigit(): st["repo_bytes"] = int(sys.argv[5])
    if rc == 0:
        st["last_success_ts"] = int(time.time())
        st["last_success_iso"] = datetime.now().astimezone().isoformat(timespec="seconds")
    save(st)
    sys.exit(0)

prev = load()
st = {k: prev[k] for k in ("last_success_ts", "last_success_iso", "snapshots", "repo_bytes") if k in prev}
st.update(running=True, ok=None, started_ts=int(time.time()), percent=0, errors=0)
if len(sys.argv) > 2 and sys.argv[2].isdigit():
    st["office_free_bytes"] = int(sys.argv[2])
save(st)
last = 0
for line in sys.stdin:
    try:
        m = json.loads(line)
    except ValueError:
        sys.stderr.write(line); continue
    t = m.get("message_type")
    if t == "status":
        st.update(percent=round(100 * m.get("percent_done", 0), 1),
                  bytes_done=m.get("bytes_done", 0), total_bytes=m.get("total_bytes", 0),
                  files_done=m.get("files_done", 0), total_files=m.get("total_files", 0),
                  eta_s=m.get("seconds_remaining"))
        if time.time() - last >= 30:
            save(st); last = time.time()
    elif t == "error":
        st["errors"] += 1
        st["last_error"] = str(m.get("error", {}).get("message", m))[:300]
        sys.stderr.write(line)
    elif t == "summary":
        st.update(percent=100, eta_s=0, snapshot_id=m.get("snapshot_id"),
                  data_added=m.get("data_added", 0),
                  total_bytes=m.get("total_bytes_processed", st.get("total_bytes", 0)),
                  files_new=m.get("files_new"), files_changed=m.get("files_changed"))
        print(json.dumps(m), flush=True)
save(st)
