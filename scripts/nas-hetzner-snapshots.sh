#!/bin/sh
# Read-only Hetzner API: the Storage Box and its snapshots, projected to what the
# check reads. The token stays on this host. Docs: docs/runbooks/backup-restore/backup.md
set -eu

TOKEN_FILE="${HETZNER_TOKEN_FILE:-/root/.config/hetzner-readonly.token}"
API="${HETZNER_API:-https://api.hetzner.com/v1}"

if [ ! -r "$TOKEN_FILE" ]; then
  echo "NO TOKEN $TOKEN_FILE"
  exit 0
fi
token="$(cat "$TOKEN_FILE")"

get() {
  curl -sS --max-time 30 -H "Authorization: Bearer $token" "$API/$1"
}

boxes="$(get storage_boxes)" || { echo "ERROR storage_boxes call failed"; exit 0; }

# One box per project here; the id is resolved rather than pinned so a rebuilt box
# needs no edit. A project with several boxes reports every one.
ids="$(printf '%s' "$boxes" | /usr/bin/python3 -c '
import json, sys
d = json.load(sys.stdin)
if "storage_boxes" not in d:
    print("ERROR " + json.dumps(d.get("error", d))[:200], file=sys.stderr)
    raise SystemExit(1)
for b in d["storage_boxes"]:
    print(b["id"], b.get("name", ""), b.get("username", ""))
')" || { echo "ERROR could not list storage boxes (token scope?)"; exit 0; }

printf '%s\n' "$ids" | while read -r id name user; do
  [ -n "$id" ] || continue
  echo "BOX $id $name $user"
  get "storage_boxes/$id/snapshots" | /usr/bin/python3 -c '
import json, sys
d = json.load(sys.stdin)
for s in d.get("snapshots", []):
    print("SNAPSHOT", s.get("created"), s.get("is_automatic"),
          (s.get("stats") or {}).get("size", 0), s.get("name"))
' || echo "ERROR snapshots call failed for box $id"
done
