# ZFS: apps + data imported as they are (PLT-1 "Facts that shape the migration").
# Nothing here may write a pool property: no extraPools (its zfs-sync-<pool> unit
# sets nixos:shutdown-time), no autotrim/trim, no zpool upgrade.
{
  config,
  lib,
  pkgs,
  nasNotify,
  ...
}:
let
  zfs = config.boot.zfs.package;
  pools = [
    "apps"
    "data"
  ];

  # Trial import: altroot /mnt over the stored mountpoints /apps and /data. After the
  # Phase 3 commit step (zfs set mountpoint=/mnt/...), drop -R here.
  importScript = pkgs.writeShellScript "zfs-import-altroot" ''
    set -u
    export PATH=${
      lib.makeBinPath [
        zfs
        pkgs.coreutils
      ]
    }
    for pool in ${lib.escapeShellArgs pools}; do
      if zpool list -H -o name "$pool" >/dev/null 2>&1; then
        echo "$pool already imported"
        continue
      fi
      for _ in $(seq 1 60); do
        zpool import -d /dev/disk/by-partuuid -N -R /mnt "$pool" && break
        sleep 1
      done
      zpool list -H -o name "$pool" >/dev/null 2>&1 || { echo "import of $pool failed"; exit 1; }
    done
  '';

  # TrueNAS-schema snapshots (auto-/daily-/weekly-/monthly-) are not sanoid's, so
  # sanoid never prunes them. Expire them with the retention of the TrueNAS task
  # that made them; nothing else is touched.
  legacyExpiry = pkgs.writeShellScript "truenas-snapshot-expiry" ''
    set -eu
    export PATH=${
      lib.makeBinPath [
        zfs
        pkgs.coreutils
        pkgs.gnugrep
      ]
    }
    now=$(date +%s)
    zfs list -H -p -t snapshot -o name -r ${lib.escapeShellArgs pools} |
      grep -E '@(auto|daily|weekly|monthly)-[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}$' |
      while read -r snap; do
        ds=''${snap%@*}
        name=''${snap#*@}
        tier=''${name%%-*}
        stamp=''${name#*-}
        case "$tier" in
          auto) case "$ds" in apps|apps/*) days=3 ;; *) days=14 ;; esac ;;
          daily) days=14 ;;
          weekly) days=56 ;;
          monthly) days=186 ;;
        esac
        hm=''${stamp#*_}
        created=$(date -d "''${stamp%_*} ''${hm/-/:}" +%s 2>/dev/null) || continue
        if [ $((now - created)) -gt $((days * 86400)) ]; then
          echo "destroying $snap (older than $days d)"
          zfs destroy "$snap"
        fi
      done
  '';
in
{
  boot.supportedFilesystems = [ "zfs" ];
  boot.zfs.forceImportRoot = false;
  boot.zfs.forceImportAll = false;
  # Same hostid as TrueNAS, so the pools import without -f in either direction.
  networking.hostId = "34ea58c7";

  systemd.services.zfs-import-altroot = {
    description = "Import ZFS pools apps and data under altroot /mnt";
    after = [
      "systemd-udev-settle.service"
      "systemd-modules-load.service"
    ];
    wants = [ "systemd-udev-settle.service" ];
    before = [
      "zfs-import.target"
      "zfs-mount.service"
      "shutdown.target"
    ];
    requiredBy = [ "zfs-import.target" ];
    conflicts = [ "shutdown.target" ];
    onFailure = [ "notify-failure@%n.service" ];
    unitConfig.DefaultDependencies = false;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = importScript;
    };
  };

  # Consumers depend on this, not on zfs-mount.service: with no pool imported,
  # `zfs mount -a` succeeds and would let them start on the empty dirs under /mnt.
  systemd.targets.nas-pools = {
    description = "Pools apps and data imported and mounted";
    requires = [
      "zfs-import-altroot.service"
      "zfs-mount.service"
    ];
    after = [
      "zfs-import-altroot.service"
      "zfs-mount.service"
    ];
    wantedBy = [ "multi-user.target" ];
  };

  # TrueNAS has autotrim off and no trim task; keep the pools as they are. fstrim
  # would walk ZFS mounts from mountinfo too, so limit it to the boot SSD's fstab.
  services.zfs.trim.enable = false;
  systemd.services.fstrim.serviceConfig.ExecStart = lib.mkForce [
    ""
    "${pkgs.util-linux}/bin/fstrim --listed-in /etc/fstab --verbose --quiet-unsupported"
  ];

  # TrueNAS: weekly slot, 35-day threshold (apps Tue, data Mon) = about monthly.
  services.zfs.autoScrub = {
    enable = true;
    pools = pools;
    interval = "Mon *-*-01..07 00:00";
    randomizedDelaySec = "0";
  };

  services.zfs.zed = {
    enableMail = false;
    settings = {
      ZED_EMAIL_ADDR = [ "root" ];
      ZED_EMAIL_PROG = "${nasNotify}/bin/nas-notify";
      ZED_EMAIL_OPTS = "-s '@SUBJECT@' @ADDRESS@";
      ZED_NOTIFY_INTERVAL_SECS = 3600;
      ZED_NOTIFY_VERBOSE = true;
    };
  };

  # The 13 TrueNAS snapshot tasks as sanoid templates. Sanoid runs every 4 h, so
  # "hourly = 18" is TrueNAS's 4-hourly, 3-day tier. Sanoid runs with TZ=UTC.
  services.sanoid = {
    enable = true;
    interval = "*-*-* 00/4:00:00 UTC";
    templates = {
      apps = {
        hourly = 18;
        daily = 14;
        weekly = 8;
        monthly = 6;
        yearly = 0;
        autosnap = true;
        autoprune = true;
      };
      data = {
        hourly = 0;
        daily = 14;
        weekly = 8;
        monthly = 6;
        yearly = 0;
        autosnap = true;
        autoprune = true;
      };
    };
    settings = lib.genAttrs [ "template_apps" "template_data" ] (_: {
      daily_hour = 0;
      daily_min = 0;
      weekly_wday = 0;
      weekly_hour = 0;
      weekly_min = 0;
      monthly_mday = 1;
      monthly_hour = 0;
      monthly_min = 0;
    });
    datasets = {
      apps = {
        useTemplate = [ "apps" ];
        recursive = true;
      };
      # Docker's data-root is re-pullable; snapshots of its layers only cost space.
      "apps/docker" = {
        autosnap = false;
        autoprune = false;
      };
      "data/smb_share" = {
        useTemplate = [ "data" ];
        recursive = true;
      };
      "data/immich".useTemplate = [ "data" ];
    };
  };

  # The module's ExecStartPre/StopPost run `zfs allow`/`unallow` for its DynamicUser,
  # which writes delegations to the pools on every run. Run as root instead.
  systemd.services.sanoid = {
    after = [ "nas-pools.target" ];
    requires = [ "nas-pools.target" ];
    onFailure = [ "notify-failure@%n.service" ];
    serviceConfig = {
      DynamicUser = lib.mkForce false;
      User = lib.mkForce "root";
      Group = lib.mkForce "root";
      ExecStartPre = lib.mkForce [ ];
      ExecStopPost = lib.mkForce [ ];
    };
  };

  systemd.services.truenas-snapshot-expiry = {
    description = "Expire TrueNAS-schema snapshots by their old task retention";
    after = [ "nas-pools.target" ];
    requires = [ "nas-pools.target" ];
    onFailure = [ "notify-failure@%n.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = legacyExpiry;
    };
  };
  systemd.timers.truenas-snapshot-expiry = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 00/4:30:00";
      Persistent = true;
    };
  };

  # TrueNAS: SHORT Mon-Fri+Sun 02:00, LONG Sat 02:00, all disks. NVMe included,
  # which replaces nvme-smart-test.sh. DEVICESCAN keeps disk serials out of git.
  services.smartd = {
    enable = true;
    autodetect = true;
    defaults.autodetected = "-a -o on -S on -n standby,q -s (S/../../[1-57]/02|L/../../6/02) -W 4,45,55";
    notifications = {
      wall.enable = false;
      mail = {
        enable = true;
        recipient = "root";
        mailer = "${nasNotify}/bin/nas-notify";
      };
    };
  };
}
