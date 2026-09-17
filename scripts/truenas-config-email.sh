#!/bin/sh
# Email a TrueNAS config backup as a MIME attachment via mail.send's /_upload job
# endpoint (the WebSocket caps at 64 kB). Docs: docs/runbooks/backup-restore/truenas-config-backup.md

set -eu

RECIPIENT="${1:-you@example.com}"
# Optional Uptime-Kuma push monitor, pinged on success. Host file, not the repo.
PUSH_URL_FILE="/root/.config/config-email-kuma-push.url"
STAMP="$(date +%Y-%m-%d)"
HOST="$(hostname -s)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FNAME="truenas-config-${STAMP}.tar.gz"
TARBALL="$TMP/$FNAME"
# Config DB only — pwenc_secret is deliberately excluded; it lives in Bitwarden.
tar -czf "$TARBALL" -C /data freenas-v1.db

# Ephemeral, single-use token (ttl 300s, origin check off so curl can present it).
TOKEN="$(midclt call auth.generate_token 300 '{}' false true | tr -d '"')"

SUBJECT="TrueNAS config backup - ${HOST} (${STAMP})"
BODY="TrueNAS config backup ${STAMP} attached (${FNAME}).

Contents = freenas-v1.db (full system config; stored secrets are encrypted).
The decryption seed (pwenc_secret) is NOT in this file - it lives in Bitwarden.

Restore: System -> General -> Manage Configuration -> Upload Config, then re-apply the
pwenc_secret seed from Bitwarden. See docs/runbooks/backup-restore/truenas-config-backup.md."

# The data part must come first; attachments:true makes mail.send read the uploaded
# "file" part as a JSON list of attachment dicts. Written to a file to dodge quoting.
DATAJSON="$TMP/data.json"
python3 - "$SUBJECT" "$RECIPIENT" "$BODY" "$DATAJSON" <<'PY'
import sys, json
subject, recipient, body, out = sys.argv[1:5]
with open(out, "w") as f:
    json.dump({
        "method": "mail.send",
        "params": [{
            "subject": subject,
            "to": [recipient],
            "text": body,
            "attachments": True,
        }],
    }, f)
PY

# Attachments JSON: the tarball base64'd as the single attachment's content.
ATTACH="$TMP/attach.json"
python3 - "$TARBALL" "$FNAME" "$ATTACH" <<'PY'
import sys, json, base64
tarball, fname, out = sys.argv[1:4]
with open(tarball, "rb") as f:
    content = base64.b64encode(f.read()).decode()
attachments = [{
    "headers": [
        {"name": "Content-Transfer-Encoding", "value": "base64"},
        {"name": "Content-Type", "value": "application/gzip", "params": {"name": fname}},
        {"name": "Content-Disposition", "value": "attachment", "params": {"filename": fname}},
    ],
    "content": content,
}]
with open(out, "w") as f:
    json.dump(attachments, f)
PY

# /_upload is proxied by nginx to 127.0.0.1:6000; hit it directly to skip TLS.
RESP="$TMP/resp.json"
CODE=$(curl -s -o "$RESP" -w '%{http_code}' -X POST \
    -H "Authorization: Token $TOKEN" \
    -F "data=<$DATAJSON;type=application/json" \
    -F "file=@${ATTACH};type=application/json" \
    http://127.0.0.1:6000/_upload)

if [ "$CODE" != "200" ]; then
    echo "config email failed (HTTP $CODE):" >&2
    cat "$RESP" >&2
    exit 1
fi
echo "Config backup emailed to $RECIPIENT (job: $(cat "$RESP"))"

# Success -> ping the Kuma heartbeat if one is configured.
if [ -r "$PUSH_URL_FILE" ]; then
    url="$(cat "$PUSH_URL_FILE")"
    [ -n "$url" ] && curl -fsS -m 15 "$url" >/dev/null 2>&1 || true
fi
