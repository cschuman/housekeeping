#!/usr/bin/env bash
# Seed known-recipients.txt (next to this script) from the last 90 days of sent
# mail. Read-only gws calls only: messages list + messages get (metadata, To/Cc/Bcc).
# Prints only counts, never addresses. Never wrap gws in `env -i` (it deletes the
# Gmail credentials).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/known-recipients.txt"
command -v gws >/dev/null || { echo "gws not found" >&2; exit 1; }

python3 - "$OUT" <<'PY'
import concurrent.futures as cf, datetime, email.utils, json, os, subprocess, sys, tempfile

out = sys.argv[1]
MUST = ["kavs68@gmail.com", "cschuman@gmail.com"]

def gws(*args):
    r = subprocess.run(["gws", *args], capture_output=True, text=True, timeout=60)
    t = r.stdout
    if r.returncode != 0 or "{" not in t:
        raise RuntimeError(f"gws exit {r.returncode}")
    return json.loads(t[t.index("{"):])

ids, token = [], None
for page in range(5):
    params = {"userId": "me", "q": "in:sent newer_than:90d", "maxResults": 100}
    if token:
        params["pageToken"] = token
    d = gws("gmail", "users", "messages", "list", "--params", json.dumps(params))
    ids += [m["id"] for m in d.get("messages", []) if "id" in m]
    token = d.get("nextPageToken")
    if not token:
        break

def headers(mid):
    p = {"userId": "me", "id": mid, "format": "metadata", "metadataHeaders": ["To", "Cc", "Bcc"]}
    for attempt in range(2):
        try:
            d = gws("gmail", "users", "messages", "get", "--params", json.dumps(p))
            return [h.get("value", "") for h in d.get("payload", {}).get("headers", [])
                    if h.get("name", "").lower() in ("to", "cc", "bcc")]
        except Exception:
            if attempt:
                return None

addrs, failed = set(), 0
with cf.ThreadPoolExecutor(max_workers=6) as ex:
    for vals in ex.map(headers, ids):
        if vals is None:
            failed += 1
            continue
        addrs |= {a.strip().lower() for _, a in email.utils.getaddresses(vals) if "@" in a}
addrs |= set(MUST)

fd, tmp = tempfile.mkstemp(dir=os.path.dirname(out), prefix=".known-recipients.")
with os.fdopen(fd, "w") as fh:
    fh.write(f"# seeded {datetime.date.today().isoformat()} from 90d sent mail; one address per line\n")
    fh.write("".join(a + "\n" for a in sorted(addrs)))
os.chmod(tmp, 0o600)
os.replace(tmp, out)
print(f"seed-known-recipients: {len(ids)} sent messages scanned, {failed} failed, {len(addrs)} addresses -> {out}")
PY
