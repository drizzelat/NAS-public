# BAK-1: restic from ZFS snapshots to the Hetzner Storage Box, replacing cloudsync-chain.sh.
# Same dataset set as the chain: every apps filesystem minus its exclusions, and the data
# whitelist (DATA_INCLUDE). The snapshot name is fixed, so restic sees stable paths.
{
  lib,
  pkgs,
  config,
  ...
}:
let
  zfs = config.boot.zfs.package;
  snap = "restic";
  roots = [
    "apps"
    "data/immich"
    "data/smb_share"
  ];
  # cloudsync-chain.sh APPS_EXCLUDE, plus the re-pullable Docker data-root.
  exclude = [
    "apps/.system"
    "apps/.ix-virt"
    "apps/ix-apps"
    "apps/tailscale"
    "apps/docker"
  ];

  prepare = pkgs.writeShellScript "restic-zfs-snapshot" ''
    set -eu
    for r in ${lib.escapeShellArgs roots}; do
      ${zfs}/bin/zfs destroy -r "$r@${snap}" 2>/dev/null || true
      ${zfs}/bin/zfs snapshot -r "$r@${snap}"
    done
  '';

  # One path per mounted filesystem: <mountpoint>/.zfs/snapshot/restic.
  listPaths = pkgs.writeShellScript "restic-zfs-paths" ''
    set -eu
    ${zfs}/bin/zfs list -H -t filesystem -o name,canmount,mounted,mountpoint -r ${lib.escapeShellArgs roots} |
      while IFS="$(printf '\t')" read -r name canmount mounted mp; do
        [ "$canmount" = on ] && [ "$mounted" = yes ] || continue
        case "$name" in
          ${lib.concatMapStringsSep "|" (e: "${e}|${e}/*") exclude}) continue ;;
        esac
        echo "$mp/.zfs/snapshot/${snap}"
      done
  '';

  cleanup = pkgs.writeShellScript "restic-zfs-snapshot-destroy" ''
    for r in ${lib.escapeShellArgs roots}; do
      ${zfs}/bin/zfs destroy -r "$r@${snap}" 2>/dev/null || true
    done
  '';

  # OBS-2 "last successful backup older than 26 h": node exporter textfile metric.
  textfileDir = "/mnt/apps/observability/textfile"; # stacks/observability's node-exporter reads it
  markSuccess = pkgs.writeShellScript "restic-mark-success" ''
    mkdir -p ${textfileDir}
    printf 'restic_last_success_timestamp_seconds{repo="storagebox"} %s\n' "$(date +%s)" \
      > ${textfileDir}/restic.prom.tmp
    mv ${textfileDir}/restic.prom.tmp ${textfileDir}/restic.prom
  '';

  sftp = "ssh -p 23 -i ${
    config.age.secrets.restic-ssh-key.path or "/run/agenix/restic-ssh-key"
  } -o StrictHostKeyChecking=yes u000000@u000000.your-storagebox.de -s sftp";
in
{
  # Storage Box host key on port 23, read 2026-09-27 while installing the restic key.
  programs.ssh.knownHosts.storagebox = {
    hostNames = [ "[u000000.your-storagebox.de]:23" ];
    publicKey = "ssh-ed25519 <redacted>";
  };

  services.restic.backups.storagebox = {
    # Initialised 2026-09-27; never auto-create one. Port 23 is SSH with /home as the
    # box's root (port 22's /backup is /home/backup here).
    initialize = false;
    repository = "sftp:u000000@u000000.your-storagebox.de:/home/restic/nas";
    passwordFile = config.age.secrets.restic-password.path or "/run/agenix/restic-password";
    extraOptions = [ "sftp.command='${sftp}'" ];
    backupPrepareCommand = "${prepare}";
    dynamicFilesFrom = "${listPaths}";
    backupCleanupCommand = "${cleanup}";
    exclude = [
      "/mnt/apps/mediaserver/config/jellyfin/.zfs/snapshot/${snap}/cache"
    ];
    extraBackupArgs = [
      "--host=nas"
      "--tag=zfs"
    ];
    pruneOpts = [
      "--keep-daily 14"
      "--keep-weekly 8"
      "--keep-monthly 12"
      "--group-by host,tags" # a new dataset changes the path set; keep one retention group
    ];
    # The chain's 03:00 slot, after snapshots (00:00 UTC), A1 sync (02:00) and dumps (02:30).
    timerConfig = {
      OnCalendar = "*-*-* 03:00:00";
      Persistent = true;
    };
  };

  systemd.services.restic-backups-storagebox = {
    after = [ "nas-pools.target" ];
    requires = [ "nas-pools.target" ];
    onFailure = [ "notify-failure@%n.service" ];
    serviceConfig = {
      ExecStartPost = [ "${markSuccess}" ];
      StateDirectory = "restic";
      Nice = 10;
      IOSchedulingClass = "idle";
    };
  };

  # BAK-1: a monthly partial read-back of the repository.
  systemd.services.restic-check-storagebox = {
    description = "restic check --read-data-subset=1/12 on the Storage Box repository";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    onFailure = [ "notify-failure@%n.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "/run/current-system/sw/bin/restic-storagebox check --read-data-subset=1/12";
      StateDirectory = "restic";
      CacheDirectory = "restic-backups-storagebox";
    };
  };
  systemd.timers.restic-check-storagebox = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-08 05:00:00";
      Persistent = true;
    };
  };
}
