# VM test (Phase 3 step 1): scratch pools named apps and data, laid out like the real ones
# (stored mountpoints /apps and /data, ix-apps noauto, .system legacy), imported the way
# storage.nix does it. Run: nix build .#checks.x86_64-linux.nas-pools
{ pkgs, agenix }:
pkgs.testers.runNixOSTest {
  name = "nas-pools";

  nodes.nas =
    { lib, ... }:
    {
      imports = [
        agenix.nixosModules.default
        ./default.nix
      ];
      virtualisation = {
        memorySize = 3072;
        cores = 2;
        emptyDiskImages = [
          512
          512
          512
        ];
      };
      # No hardware, network or secrets in the test VM.
      services.smartd.enable = lib.mkForce false;
      power.ups.enable = lib.mkForce false;
      systemd.services.runnervm.wantedBy = lib.mkForce [ ];
      services.tailscale.enable = lib.mkForce false;
    };

  testScript = ''
    timers = [
      "nas-pg-dump", "nas-repo-pull", "nas-renovate-trigger", "nas-docker-image-prune",
      "nas-merge-sweep-trigger", "nas-a1-file-backup", "nas-healthchecks-ping",
      "nas-health-trigger", "nas-edge-probe-trigger", "nas-deploy-state-trigger",
      "nas-tor-bridge-image-trigger", "nas-kiwix-seed", "nas-public-mirror-trigger",
      "nas-vmalert-mail", "nas-host-metrics", "nas-qbit-port-sync", "nas-periphery-update", "sanoid", "zfs-scrub", "truenas-snapshot-expiry",
      "restic-backups-storagebox", "restic-check-storagebox",
    ]

    nas.start()
    nas.wait_for_unit("multi-user.target")

    with subtest("first boot without pools: import fails, nothing starts on the empty /mnt"):
        nas.fail("systemctl is-active zfs-import-altroot.service")
        nas.fail("mountpoint -q /mnt/apps")
        nas.fail("systemctl is-active nas-pools.target")
        nas.fail("systemctl is-active samba-smbd.service")
        nas.fail("systemctl is-active docker.service")

    with subtest("create scratch pools the way TrueNAS left the real ones"):
        nas.succeed("modprobe zfs")
        for d in ["vdb", "vdc", "vdd"]:
            nas.succeed(f"printf 'label: gpt\\n,,\\n' | sfdisk -q /dev/{d}")
        nas.succeed("udevadm settle")
        nas.succeed(
            "zpool create -o ashift=12 -O acltype=posix -O compression=lz4 -O atime=off "
            "apps /dev/disk/by-partuuid/$(blkid -s PARTUUID -o value /dev/vdb1)"
        )
        nas.succeed(
            "zpool create -o ashift=12 -O acltype=posix -O compression=lz4 -O atime=off "
            "data mirror /dev/disk/by-partuuid/$(blkid -s PARTUUID -o value /dev/vdc1) "
            "/dev/disk/by-partuuid/$(blkid -s PARTUUID -o value /dev/vdd1)"
        )
        for ds in ["apps/scripts", "apps/docker", "apps/komodo", "apps/tailscale",
                   "data/immich", "data/smb_share",
                   "data/smb_share/user1", "data/smb_share/user2", "data/smb_share/shared",
                   "data/romm", "data/romm/roms"]:
            nas.succeed(f"zfs create {ds}")
        nas.succeed("zfs create -o mountpoint=/.ix-apps -o canmount=noauto apps/ix-apps")
        nas.succeed("zfs create -o mountpoint=legacy apps/.system")
        nas.succeed("zfs snapshot apps@auto-2020-01-01_00-00")
        nas.succeed("zfs snapshot apps@auto-$(date +%Y-%m-%d_%H-%M)")
        nas.succeed("zpool export apps data")

    nas.shutdown()
    nas.start()
    nas.wait_for_unit("zfs-import-altroot.service")
    nas.wait_for_unit("nas-pools.target")

    with subtest("imported under altroot /mnt, stored properties untouched"):
        for pool in ["apps", "data"]:
            nas.succeed(f"test \"$(zpool get -H -o value altroot {pool})\" = /mnt")
            nas.succeed(f"test \"$(zfs get -H -o source mountpoint {pool})\" = default")
        nas.succeed("test \"$(zfs get -H -o value mountpoint apps/ix-apps)\" = /mnt/.ix-apps")
        nas.succeed("test \"$(zfs get -H -o source mountpoint apps/ix-apps)\" = local")
        # The first reboot ran a full shutdown: extraPools' zfs-sync would have set this.
        nas.succeed("test \"$(zfs get -H -o value nixos:shutdown-time apps)\" = -")
        nas.succeed("test -z \"$(zfs allow apps)\"")

    with subtest("mounts"):
        for mp in ["/mnt/apps", "/mnt/apps/docker", "/mnt/apps/scripts", "/mnt/data/romm/roms",
                   "/mnt/data/smb_share/user1", "/mnt/data/smb_share/user2"]:
            nas.succeed(f"mountpoint -q {mp}")
        nas.fail("mountpoint -q /mnt/.ix-apps")
        nas.fail("mountpoint -q /apps")
        nas.fail("mountpoint -q /data")

    with subtest("docker on the apps/docker dataset"):
        nas.wait_for_unit("docker.service")
        nas.succeed("test \"$(docker info --format '{{.DockerRootDir}}')\" = /mnt/apps/docker")
        # stacks/nas-periphery mounts this file into the container, which has no /nix/store.
        nas.succeed("/usr/libexec/docker/cli-plugins/docker-compose version")
        nas.fail("grep -qa ld-linux-x86-64 /usr/libexec/docker/cli-plugins/docker-compose")

    with subtest("samba shares"):
        nas.wait_for_unit("samba-smbd.service")
        for share in ["user2", "shared", "user1", "roms"]:
            nas.succeed(f"testparm -s 2>/dev/null | grep -F '[{share}]'")

    with subtest("timers"):
        for t in timers:
            nas.succeed(f"systemctl is-active {t}.timer")
        nas.fail("systemctl is-enabled nas-host-deploy.timer")

    with subtest("sanoid snapshots, without zfs allow, not on apps/docker"):
        nas.succeed("systemctl start sanoid.service")  # Type=simple: returns at once
        nas.wait_until_succeeds("zfs list -H -t snapshot -o name | grep -q '^apps/komodo@autosnap_'")
        nas.wait_until_succeeds("! systemctl is-active sanoid.service")
        nas.succeed("zfs list -H -t snapshot -o name | grep -q '^apps@autosnap_'")
        nas.succeed("zfs list -H -t snapshot -o name | grep -q '^data/smb_share/user1@autosnap_'")
        nas.succeed("zfs list -H -t snapshot -o name | grep -q '^data/immich@autosnap_'")
        nas.fail("zfs list -H -t snapshot -o name | grep -q '^apps/docker@autosnap_'")
        nas.fail("zfs list -H -t snapshot -o name | grep -q '^data/romm'")
        nas.succeed("test -z \"$(zfs allow apps)\"")

    with subtest("legacy TrueNAS snapshots expire by their old retention"):
        nas.succeed("systemctl start truenas-snapshot-expiry.service")
        nas.fail("zfs list apps@auto-2020-01-01_00-00")
        nas.succeed("zfs list -H -t snapshot -o name | grep -q '^apps@auto-2'")

    with subtest("restic path list covers the chain's datasets"):
        nas.succeed("zfs snapshot -r apps@restic && zfs snapshot -r data/smb_share@restic")
        out = nas.succeed("$(ls -d /nix/store/*-restic-zfs-paths | head -1)")
        assert "/mnt/apps/scripts/.zfs/snapshot/restic" in out, out
        assert "/mnt/data/smb_share/user1/.zfs/snapshot/restic" in out, out
        assert "/mnt/apps/docker/" not in out, out
        assert "/mnt/apps/tailscale/" not in out, out
        assert ".ix-apps" not in out, out
  '';
}
