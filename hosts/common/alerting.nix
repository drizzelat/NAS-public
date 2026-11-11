# One alert sender per host: nas-notify posts to the ntfy topic URL in /run/agenix/ntfy-url;
# without it, logs at crit. Units opt in with onFailure = [ "notify-failure@%n.service" ].
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
in
{
  environment.systemPackages = [ nasNotify ];

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

  _module.args.nasNotify = nasNotify;
}
