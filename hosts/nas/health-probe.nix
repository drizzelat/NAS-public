# The nashealth forced command on NixOS (PLT-1 Phase 3 step 3): health-probe.sh with its
# PATH and root helpers pinned in the store. Root helpers take no arguments, so their
# exact sudo grants have nothing to inject into. The TrueNAS probe in scripts/ is untouched.
{ lib, pkgs, ... }:
let
  path = lib.makeBinPath [
    pkgs.coreutils
    pkgs.findutils
    pkgs.gawk
    pkgs.gitMinimal
    pkgs.gnugrep
    pkgs.gnused
    pkgs.gzip
    pkgs.procps
    (pkgs.python3.withPackages (ps: [ ps.pyyaml ])) # yaml2json
    pkgs.smartmontools
    pkgs.systemd
    pkgs.util-linux
    pkgs.zfs
    "/run/wrappers" # sudo
  ];

  smartHelper = pkgs.writeScript "nas-health-smart" (
    builtins.replaceStrings [ "/usr/sbin/smartctl" ] [ "${pkgs.smartmontools}/bin/smartctl" ] (
      builtins.readFile ../../scripts/nas-health-smart.sh
    )
  );

  # Reads the token from /root/.config (copied over from TrueNAS at cutover).
  hetznerHelper = pkgs.writeScript "nas-hetzner-snapshots" (
    builtins.replaceStrings
      [ "set -eu\n" "/usr/bin/python3" ]
      [
        "set -eu\nexport PATH=${
          lib.makeBinPath [
            pkgs.coreutils
            pkgs.curl
          ]
        }\n"
        "${pkgs.python3}/bin/python3"
      ]
      (builtins.readFile ../../scripts/nas-hetzner-snapshots.sh)
  );

  # Read-only SQLite reads of both Kuma databases, root-only files.
  kumaHelper = pkgs.writeScript "nas-health-kuma" (
    builtins.replaceStrings [ "/usr/bin/python3" ] [ "${pkgs.python3}/bin/python3" ] (
      builtins.readFile ../../scripts/nas-health-kuma.sh
    )
  );

  resticLogHelper = pkgs.writeShellScript "nas-health-restic-log" ''
    exec ${pkgs.systemd}/bin/journalctl -u restic-backups-storagebox.service -n 200 \
      --no-pager -o short-iso
  '';

  probe = pkgs.writeScriptBin "nas-health-probe" (
    builtins.replaceStrings
      [
        "#!/bin/sh\n"
        "@smartHelper@"
        "@hetznerHelper@"
        "@resticLogHelper@"
        "@kumaHelper@"
      ]
      [
        "#!${pkgs.dash}/bin/dash\nexport PATH=${path}\n"
        "${smartHelper}"
        "${hetznerHelper}"
        "${resticLogHelper}"
        "${kumaHelper}"
      ]
      (builtins.readFile ./health-probe.sh)
  );
in
{
  environment.systemPackages = [ probe ];

  # users.nix pins nashealth's key to this command.
  _module.args.nasHealthProbe = "${probe}/bin/nas-health-probe";

  security.sudo.extraRules = [
    {
      users = [ "nashealth" ];
      commands =
        map
          (c: {
            command = "${c}";
            options = [ "NOPASSWD" ];
          })
          [
            smartHelper
            hetznerHelper
            resticLogHelper
            kumaHelper
          ];
    }
  ];
}
