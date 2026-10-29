# SMB and NFS shares as TrueNAS serves them (midclt smb.config / sharing.*.query).
# Access control is the POSIX ACLs on the datasets, as on TrueNAS: no valid users lines.
{ config, lib, ... }:
let
  share =
    path: extra:
    {
      inherit path;
      browseable = "yes";
      "read only" = "no";
      "guest ok" = "no";
      # shadowcopy: Previous Versions from sanoid's snapshots (names are UTC). TrueNAS used its
      # own shadow_copy_zfs (arbitrary snapshot names); that module is TrueNAS-only, not in
      # upstream/nixpkgs Samba, so shadow_copy2 is the portable choice here. Its snapprefix/
      # delimiter/format triple below is version-finicky and cannot be verified before a real
      # sanoid snapshot exists: if Previous Versions is empty after cutover, fix shadow:format
      # (cutover runbook → Verify). Only the client-side feature is at stake — shares, the
      # snapshots and restic are unaffected. Never swap in shadow_copy_zfs: smbd would refuse it.
      # streams: alternate data streams in xattrs. durablehandle: durable handles.
      "vfs objects" = "shadow_copy2 streams_xattr";
      "shadow:snapdir" = ".zfs/snapshot";
      "shadow:sort" = "desc";
      "shadow:snapprefix" = "^autosnap";
      "shadow:delimiter" = "_";
      "shadow:format" = "_%Y-%m-%d_%H:%M:%S";
      "shadow:localtime" = "no";
      "durable handles" = "yes";
      "kernel oplocks" = "no";
      "kernel share modes" = "no";
      "posix locking" = "no";
      "ea support" = "yes";
      "store dos attributes" = "yes";
    }
    // extra;
in
{
  services.samba = {
    enable = true;
    openFirewall = true;
    nmbd.enable = true; # TrueNAS service_announcement.netbios
    winbindd.enable = false;
    settings = {
      global = {
        "netbios name" = "truenas";
        workgroup = "WORKGROUP";
        "server string" = "TrueNAS Server";
        "server role" = "standalone server";
        security = "user";
        "passdb backend" = "tdbsam";
        "server min protocol" = "SMB2_02"; # enable_smb1 false
        "unix charset" = "UTF-8";
        "server multi channel support" = "no";
        "server smb encrypt" = "default";
        "guest account" = "nobody";
        "map to guest" = "Never";
        "restrict anonymous" = "2";
        "local master" = "yes";
        "load printers" = "no";
        printing = "bsd";
        "printcap name" = "/dev/null";
        "disable spoolss" = "yes";
      };
      user2 = share "/mnt/data/smb_share/user2" { };
      shared = share "/mnt/data/smb_share/shared" { };
      user1 = share "/mnt/data/smb_share/user1" { };
      roms = share "/mnt/data/romm/roms" {
        comment = "RomM ROM library (GameCube/Wii/Switch read by native emulators on the client)";
      };
    };
  };

  # TrueNAS service_announcement.wsd (Windows network browsing). mDNS stays off.
  services.samba-wsdd = {
    enable = true;
    openFirewall = true;
  };

  # TrueNAS NFS exports: no host or network restriction, read-write.
  services.nfs.server = {
    enable = true;
    exports = ''
      /mnt/data/smb_share/user1 *(rw,sync,no_subtree_check,sec=sys)
      /mnt/data/smb_share/shared *(rw,sync,no_subtree_check,sec=sys)
    '';
    statdPort = 4000;
    lockdPort = 4001;
    mountdPort = 4002;
  };
  networking.firewall = {
    allowedTCPPorts = [
      111
      2049
      4000
      4001
      4002
    ];
    allowedUDPPorts = [
      111
      2049
      4000
      4001
      4002
    ];
  };

  # Shares live on the pools: never serve the empty directories under /mnt.
  systemd.services =
    lib.genAttrs ([ "samba-smbd" ] ++ lib.optional config.services.nfs.server.enable "nfs-server")
      (_: {
        after = [ "nas-pools.target" ];
        requires = [ "nas-pools.target" ];
      });
}
