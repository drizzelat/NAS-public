# Local replica of apps on the old TrueNAS boot SSD (pool `replica`, mountpoint none): after an
# NVMe loss, apps comes back by a local zfs send. Docs: docs/runbooks/backup-restore/local-replica.md
{
  config,
  lib,
  pkgs,
  ...
}:
let
  zfs = config.boot.zfs.package;

  importScript = pkgs.writeShellScript "zfs-import-replica" ''
    ${zfs}/bin/zpool list -H -o name replica >/dev/null 2>&1 && exit 0
    exec ${zfs}/bin/zpool import -d /dev/disk/by-id -N -o cachefile=none replica
  '';
in
{
  # Not part of nas-pools.target: a dead replica SSD must not keep Docker down.
  systemd.services.zfs-import-replica = {
    description = "Import ZFS pool replica (local copy of apps)";
    after = [ "zfs-import-pools.service" ];
    wantedBy = [ "multi-user.target" ];
    onFailure = [ "notify-failure@%n.service" ];
    restartIfChanged = false;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = importScript;
    };
  };

  # Only sanoid's snapshots travel, and the target drops what sanoid pruned on the source.
  systemd.services.zfs-replica = {
    description = "Replicate apps to the local replica pool";
    after = [
      "nas-pools.target"
      "zfs-import-replica.service"
    ];
    requisite = [ "nas-pools.target" ]; # timer-driven: never start the pool import (timers.nix)
    requires = [ "zfs-import-replica.service" ];
    onFailure = [ "notify-failure@%n.service" ];
    environment.HOME = "/root"; # mbuffer warns on every send without it
    serviceConfig = {
      Type = "oneshot";
      Nice = 10;
      IOSchedulingClass = "idle";
      ExecStart = lib.escapeShellArgs [
        "${pkgs.sanoid}/bin/syncoid"
        "--recursive"
        "--no-sync-snap"
        "--delete-target-snapshots"
        "--include-snaps=^autosnap_"
        "--exclude-datasets=^apps/(docker|runner-vm)(/|$)" # re-pullable / the runner's churn
        "--recvoptions=u"
        "--quiet"
        "apps"
        "replica/apps"
      ];
    };
  };
  systemd.timers.zfs-replica = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 00/4:20:00 UTC"; # 20 min after each sanoid run
      Persistent = true;
    };
  };
}
