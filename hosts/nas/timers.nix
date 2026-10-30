# OPS-1: the TrueNAS cron jobs (midclt cronjob.query) as systemd timers. Scripts still run
# from the auto-pulled clone (docs/scheduled-tasks.md); only who fires them changes.
# Times are local (Europe/Berlin), as TrueNAS cron. Persistent= fires a missed run at boot.
{
  lib,
  pkgs,
  midclt,
  ...
}:
let
  clone = "/mnt/apps/scripts/nas/scripts";

  # TrueNAS cron id in the comment. `at` is a systemd OnCalendar (string or list).
  jobs = {
    pg-dump = {
      # 2
      description = "Postgres/MariaDB dumps";
      script = "${clone}/pg-dump-backup.sh";
      at = "*-*-* 02:30:00";
    };
    repo-pull = {
      # 5; the puller lives outside the clone on purpose
      description = "NAS repo auto-pull (main)";
      script = "/mnt/apps/scripts/git-pull-nas.sh";
      at = "*-*-* *:07,22,37,52:00";
    };
    renovate-trigger = {
      # 6
      description = "Renovate trigger";
      script = "${clone}/renovate-trigger.sh";
      at = "*-*-* 04:15:00";
    };
    docker-image-prune = {
      # 8
      description = "Docker image auto-prune (unused >7d)";
      script = "${clone}/docker-image-prune.sh";
      at = "Sun *-*-* 04:30:00";
    };
    merge-sweep-trigger = {
      # 12
      description = "Renovate merge sweep (window-merge dispatch)";
      script = "${clone}/merge-sweep-trigger.sh";
      at = "*-*-* 05:20:00";
    };
    a1-file-backup = {
      # 13
      description = "A1 file sync (kuma)";
      script = "${clone}/a1-file-backup.sh";
      at = "*-*-* 02:00:00";
    };
    healthchecks-ping = {
      # 14
      description = "healthchecks.io heartbeat";
      script = "${clone}/healthchecks-ping.sh";
      at = "*-*-* *:*:00";
      quiet = true;
    };
    health-trigger = {
      # 15
      description = "nas-health-check on-time trigger";
      script = "${clone}/nas-health-trigger.sh";
      at = "*-*-* 06:30:00";
    };
    edge-probe-trigger = {
      # 16
      description = "edge-access-policy on-time trigger";
      script = "${clone}/edge-probe-trigger.sh";
      at = "*-*-* 00,06,12,18:17:00";
    };
    deploy-state-trigger = {
      # 17
      description = "deploy-state-probe on-time trigger";
      script = "${clone}/deploy-state-trigger.sh";
      at = "*-*-* 03,09,15,21:47:00";
    };
    tor-bridge-image-trigger = {
      # 18
      description = "Tor bridge image freshness checks";
      script = "${clone}/tor-bridge-image-trigger.sh";
      at = "*-*-* 03:40:00";
    };
    kiwix-seed = {
      # 19
      description = "Kiwix seeding";
      script = "${clone}/kiwix-seed.sh";
      at = "Wed *-*-* 04:45:00";
    };
    public-mirror-trigger = {
      # 21
      description = "public-mirror daily trigger";
      script = "${clone}/public-mirror-trigger.sh";
      at = "*-*-* 12:00:00";
    };
    restore-drill = {
      # 22; restores from restic, after the 03:00 backup
      description = "Monthly automated restore drill";
      script = "${clone}/restore-drill-auto.sh";
      at = "Sun *-*-01..07 05:00:00";
    };
    vmalert-mail = {
      # 23
      description = "vmalert mail bridge";
      script = "${clone}/vmalert-mail.sh";
      at = "*-*-* *:00/15:00";
    };
    host-metrics = {
      # 24
      description = "Host metrics textfile (node-exporter)";
      script = "${clone}/host-metrics.sh";
      at = "*-*-* *:00/5:00";
      quiet = true;
    };
    qbit-port-sync = {
      # 25
      description = "qBittorrent forwarded-port sync";
      script = "${clone}/qbit-port-sync.sh";
      at = "*-*-* *:00/2:00";
    };
    periphery-update = {
      # 26; bash, not dash. Applies the NAS periphery too (stacks/nas-periphery), keep 00:40-00:50 UTC free
      description = "Komodo periphery auto-apply";
      script = "${clone}/periphery-update.sh";
      shell = "${pkgs.bash}/bin/bash";
      at = "*-*-* *:51:00";
    };
  };

  # Replaced, not ported (PLT-1 "What changes in the repo"):
  #   3  truenas-config-email.sh  the repo is the config now
  #   4  cloudsync-chain.sh       restic from snapshots, backup.nix (BAK-1)
  #   10, 11 nvme-smart-test.sh   smartd schedules NVMe self-tests, storage.nix
  #   init docker-boot-guard.sh   docker.service asserts its mount, docker.nix
  #   init ethtool --set-eee      .link file, network.nix

  # What the scripts call. dash, not bash: TrueNAS's /bin/sh is dash.
  jobPath = [
    midclt
    pkgs.bash # periphery-apply.sh: env bash, /dev/tcp
    pkgs.coreutils
    pkgs.curl
    pkgs.docker
    pkgs.findutils
    pkgs.gawk
    pkgs.gitMinimal
    pkgs.gnugrep
    pkgs.gnused
    pkgs.gzip
    pkgs.inetutils
    pkgs.jq
    pkgs.openssh
    pkgs.procps
    pkgs.python3
    pkgs.rsync
    pkgs.smartmontools
    pkgs.sqlite
    pkgs.util-linux
    pkgs.zfs
  ];

  mkService = name: job: {
    inherit (job) description;
    after = [
      "nas-pools.target"
      "docker.service"
      "network-online.target"
    ];
    wants = [ "network-online.target" ];
    requires = [ "nas-pools.target" ];
    onFailure = [ "notify-failure@%n.service" ];
    path = jobPath;
    environment.HOME = "/root";
    restartIfChanged = false;
    unitConfig.RequiresMountsFor = [ "/mnt/apps/scripts" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${job.shell or "${pkgs.dash}/bin/dash"} ${job.script}";
    }
    // lib.optionalAttrs (job.quiet or false) {
      StandardOutput = "null";
      LogLevelMax = "notice";
    };
  };

  mkTimer = name: job: {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = job.at;
      Persistent = true;
    };
  };
in
{
  systemd.services = lib.mapAttrs' (n: j: lib.nameValuePair "nas-${n}" (mkService n j)) jobs;
  systemd.timers = lib.mapAttrs' (n: j: lib.nameValuePair "nas-${n}" (mkTimer n j)) (
    lib.filterAttrs (_: j: j.at != null) jobs
  );
}
