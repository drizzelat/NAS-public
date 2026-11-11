# The A1's host jobs, formerly /etc/cron.d and a hand-made timer. Scripts run from deploy.nix's
# clone (Ubuntu used Komodo's, which only moves on an A1 stack deploy). Times are UTC.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  clone = "/var/lib/a1-host-deploy/nas/scripts";

  jobs = {
    host-metrics = {
      description = "Host metrics textfile (node-exporter)";
      script = "${clone}/host-metrics.sh containers";
      at = "*-*-* *:00/5:00";
      environment.OUT_DIR = "/var/lib/node-exporter-textfile";
      quiet = true;
    };
    healthchecks-ping = {
      description = "healthchecks.io heartbeat";
      script = "${clone}/healthchecks-ping.sh";
      at = "*-*-* *:*:00";
      environment = {
        HC_URL_FILE =
          config.age.secrets.a1-healthchecks-ping-url.path or "/run/agenix/a1-healthchecks-ping-url";
        HC_GUARD_FILE = "${pkgs.writeText "healthchecks-guard.container" "a1-webtunnel"}";
      };
      quiet = true;
    };
    docker-image-prune = {
      description = "Docker image auto-prune (unused >7d)";
      script = "${clone}/docker-image-prune.sh";
      at = "Sun *-*-* 04:30:00";
      alert = true;
    };
  };

  jobPath = [
    pkgs.coreutils
    pkgs.curl
    config.virtualisation.docker.package
    pkgs.findutils
    pkgs.gawk
    pkgs.gnugrep
    pkgs.gnused
    pkgs.procps
    pkgs.python3
    pkgs.smartmontools # host-metrics.sh probes for disks; none answer on OCI
    pkgs.util-linux
  ];

  mkService = _: job: {
    inherit (job) description;
    after = [
      "docker.service"
      "network-online.target"
    ];
    wants = [ "network-online.target" ];
    # The every-minute and 5-minute jobs stay quiet: healthchecks.io and Grafana see them fail.
    onFailure = lib.optional (job.alert or false) "notify-failure@%n.service";
    path = jobPath;
    environment = {
      HOME = "/root";
    }
    // (job.environment or { });
    restartIfChanged = false;
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.dash}/bin/dash ${job.script}";
    }
    // lib.optionalAttrs (job.quiet or false) {
      StandardOutput = "null";
      LogLevelMax = "notice";
    };
  };

  mkTimer = _: job: {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = job.at;
      Persistent = true;
    };
  };
in
{
  systemd.services = lib.mapAttrs mkService jobs;
  systemd.timers = lib.mapAttrs mkTimer jobs;

  # node-exporter (stacks/a1-vps-node-exporter) bind-mounts these.
  systemd.tmpfiles.rules = [
    "d /var/lib/node-exporter-textfile 0755 root root -"
    "d /var/lib/node-exporter-probe 0755 root root -"
  ];
}
