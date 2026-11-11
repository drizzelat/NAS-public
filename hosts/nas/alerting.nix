# zed, smartd, OnFailure= and restic alert through nas-notify (hosts/common/alerting.nix)
# until OBS-1b lands. This module adds the midclt shim the timer scripts still call.
{ pkgs, nasNotify, ... }:
let
  # The timer scripts alert through `midclt call mail.config` / `mail.send`. This shim
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
  environment.systemPackages = [ midclt ];

  _module.args.midclt = midclt;
}
