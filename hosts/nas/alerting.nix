# One alert sender for zed, smartd, OnFailure= and restic until OBS-1b lands.
# Posts to the ntfy topic URL in /run/agenix/ntfy-url; without it, logs at crit.
{ lib, pkgs, ... }:
let
  # writeShellScriptBin, not writeShellApplication: ShellCheck is not in the offline cache.
  # Accepts `-s subject` (zed, own callers) or a sendmail-style message with a
  # Subject: header on stdin (smartd). Other arguments (recipients, -i) are ignored.
  nasNotify = pkgs.writeShellScriptBin "nas-notify" ''
    set -euo pipefail
    export PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.curl
        pkgs.gnugrep
        pkgs.gnused
        pkgs.inetutils
        pkgs.util-linux
      ]
    }
    subject=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -s) subject="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    body="$(cat)"
    if [ -z "$subject" ]; then
      subject="$(printf '%s\n' "$body" | grep -m1 '^Subject: ' | sed 's/^Subject: //' || true)"
    fi
    subject="''${subject:-alert from $(hostname)}"

    logger -t nas-notify -p daemon.crit -- "$subject"
    url_file=/run/agenix/ntfy-url
    if [ ! -r "$url_file" ]; then
      echo "nas-notify: $url_file missing, alert only logged" >&2
      exit 1
    fi
    printf '%s\n' "''${body:0:3500}" |
      curl -fsS --max-time 20 --retry 3 \
        -H "Title: $(hostname): $subject" -H "Priority: high" \
        --data-binary @- "$(cat "$url_file")" >/dev/null
  '';

  # The cron scripts alert through `midclt call mail.config` / `mail.send`. This shim
  # answers exactly those two and hands the mail to nas-notify; everything else fails.
  midclt = pkgs.writeShellScriptBin "midclt" ''
    set -eu
    case "''${1:-} ''${2:-}" in
      "call mail.config") echo '{"fromemail": "root"}' ;;
      "call mail.send")
        subject=$(printf '%s' "$3" | ${pkgs.jq}/bin/jq -r '.subject // "mail.send"')
        printf '%s' "$3" | ${pkgs.jq}/bin/jq -r '.text // ""' |
          ${nasNotify}/bin/nas-notify -s "$subject"
        ;;
      *)
        echo "midclt shim: '$*' does not exist on NixOS (only mail.config, mail.send)" >&2
        exit 1
        ;;
    esac
  '';
in
{
  environment.systemPackages = [
    nasNotify
    midclt
  ];

  # OnFailure=notify-failure@%n on every scheduled job (OPS-1).
  systemd.services."notify-failure@" = {
    description = "Alert on failure of %i";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.writeShellScript "notify-failure" ''
        ${pkgs.systemd}/bin/journalctl -u "$1" -n 40 --no-pager -o cat |
          ${nasNotify}/bin/nas-notify -s "unit failed: $1"
      ''} %i";
    };
  };

  _module.args = { inherit nasNotify midclt; };
}
