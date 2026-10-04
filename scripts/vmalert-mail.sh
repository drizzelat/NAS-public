#!/bin/sh
# Mail vmalert's firing alerts. vmalert has no Alertmanager (-notifier.blackhole): the only
# mail path on this estate is TrueNAS's OAuth sender, which no container can use.
# Docs: docs/services/observability.md#alerting

set -u

VMALERT_URL="${VMALERT_URL:-http://127.0.0.1:8880}"
STATE=/root/.local/state/vmalert-mailed
LOG=/var/log/vmalert-mail.log
# healthchecks.io ping URL for the Watchdog rule; host file, never the repo (it is a credential).
HC_URL_FILE="${HC_URL_FILE:-/root/.config/vmalert-watchdog.url}"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >>"$LOG"; }

hc_ping() {  # $1 = "" for success or "/fail"; body on stdin
  [ -r "$HC_URL_FILE" ] || { log "no watchdog URL at $HC_URL_FILE"; return; }
  url="$(cat "$HC_URL_FILE")"
  [ -n "$url" ] || return
  curl -fsS -m 10 --retry 2 --retry-delay 3 --data-binary @- "${url%/}$1" >/dev/null 2>&1 \
    || log "could not reach healthchecks.io"
}

MAILTO="$(midclt call mail.config 2>/dev/null \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("fromemail") or "")' 2>/dev/null)"

send_mail() {  # $1 = subject; body on stdin
  [ -n "$MAILTO" ] || { log "no mail recipient configured — cannot send"; return; }
  SUBJ="$1" TO="$MAILTO" python3 -c '
import os, sys, json, subprocess
payload = json.dumps({"subject": os.environ["SUBJ"],
                      "text": sys.stdin.read(),
                      "to": [os.environ["TO"]]})
subprocess.run(["midclt", "call", "mail.send", payload],
               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
' 2>/dev/null || true
}

alerts="$(curl -fsS -m 20 "$VMALERT_URL/api/v1/alerts" 2>/dev/null)" || {
  log "vmalert unreachable at $VMALERT_URL"
  echo "vmalert unreachable at $VMALERT_URL" | hc_ping /fail
  echo "vmalert-mail: vmalert unreachable at $VMALERT_URL" >&2
  exit 1
}

# Watchdog always fires while vmalert evaluates rules; its absence means the rules stopped.
if printf '%s' "$alerts" | python3 -c '
import sys, json
d = json.load(sys.stdin)
sys.exit(0 if any(a.get("state") == "firing" and (a.get("labels") or {}).get("alertname") == "Watchdog"
                  for a in (d.get("data") or {}).get("alerts", [])) else 1)
' 2>/dev/null; then
  echo "Watchdog firing" | hc_ping ""
else
  echo "vmalert is up but Watchdog is not firing" | hc_ping /fail
  log "Watchdog not firing"
fi

mkdir -p "$(dirname "$STATE")"
touch "$STATE"

# One line per firing alert, "<fingerprint><TAB><one-line summary>". The fingerprint is
# the alert name plus its labels, so the same alert is mailed once, not every run.
now="$(printf '%s' "$alerts" | python3 -c '
import sys, json
d = json.load(sys.stdin)
for a in (d.get("data") or {}).get("alerts", []):
    if a.get("state") != "firing":
        continue
    labels = a.get("labels") or {}
    ann = a.get("annotations") or {}
    name = labels.get("alertname", "?")
    if name == "Watchdog":
        continue
    fp = name + "{" + ",".join(f"{k}={v}" for k, v in sorted(labels.items()) if k != "alertname") + "}"
    line = "%s [%s] %s -- %s (runbook: %s)" % (
        name, labels.get("severity", "?"), ann.get("summary", ""),
        ann.get("description", ""), ann.get("runbook", "-"))
    print(fp + "\t" + line.replace("\n", " "))
')"

new="$(printf '%s\n' "$now" | grep . | while IFS="$(printf '\t')" read -r fp line; do
  grep -qxF "$fp" "$STATE" || printf '%s\t%s\n' "$fp" "$line"
done)"

resolved="$(while read -r fp; do
  [ -n "$fp" ] || continue
  printf '%s\n' "$now" | cut -f1 | grep -qxF "$fp" || printf '%s\n' "$fp"
done <"$STATE")"

if [ -n "$new" ]; then
  n="$(printf '%s\n' "$new" | grep -c .)"
  { printf 'vmalert is firing %s new alert(s) on %s at %s:\n\n' \
      "$n" "$(hostname)" "$(date '+%Y-%m-%d %H:%M:%S')"
    printf '%s\n' "$new" | cut -f2- | sed 's/^/  - /'
    printf '\nAll firing alerts: %s/vmalert/alerts\n' "$VMALERT_URL"
  } | send_mail "[NAS] vmalert: $n new alert(s)"
  log "mailed $n new alert(s)"
fi

if [ -n "$resolved" ]; then
  n="$(printf '%s\n' "$resolved" | grep -c .)"
  { printf '%s vmalert alert(s) resolved on %s at %s:\n\n' \
      "$n" "$(hostname)" "$(date '+%Y-%m-%d %H:%M:%S')"
    printf '%s\n' "$resolved" | sed 's/^/  - /'
  } | send_mail "[NAS] vmalert: $n alert(s) resolved"
  log "mailed $n resolved alert(s)"
fi

printf '%s\n' "$now" | cut -f1 | grep . > "$STATE.new" 2>/dev/null || : > "$STATE.new"
mv "$STATE.new" "$STATE"
exit 0
