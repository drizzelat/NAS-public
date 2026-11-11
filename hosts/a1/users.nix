# `ubuntu` kept (uid 1001): runbooks, the NAS's ssh aliases and the probes all log in as it.
# Not in the docker group, as on Ubuntu: `sudo docker`.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  # scripts/periphery-apply.sh, the forced command of the NAS's periphery-update timer
  # (docs/runbooks/setup-operations/periphery-auto-apply.md). Was /usr/local/sbin/periphery-apply.
  peripheryApply = pkgs.writeShellScript "periphery-apply" ''
    export PATH=${
      lib.makeBinPath [
        pkgs.bash
        pkgs.coreutils
        config.virtualisation.docker.package
        pkgs.findutils
        pkgs.gawk
        pkgs.python3
        pkgs.util-linux
      ]
    }
    exec ${pkgs.bash}/bin/bash ${../../scripts/periphery-apply.sh} "$@"
  '';
in
{
  users.users.ubuntu = {
    uid = 1001;
    isNormalUser = true;
    group = "ubuntu";
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [
      # secrets/ssh/ssh-a1-key.key, the admin key
      "ssh-rsa <redacted> ssh-key-2026-07-08"
      # NAS nightly a1-file-backup: read-only rsync of the Kuma data dir only.
      ''restrict,command="${pkgs.rrsync}/bin/rrsync -ro /opt/kuma/data" ssh-ed25519 <redacted> nas-root-a1_backup_kuma''
      ''restrict,command="/run/wrappers/bin/sudo ${peripheryApply}" ssh-ed25519 <redacted> periphery-update a1''
    ];
    # Serial-console break-glass: a crypt hash from the vault, when the secret exists.
    hashedPasswordFile = lib.mkIf (
      config.age.secrets ? a1-ubuntu-password
    ) config.age.secrets.a1-ubuntu-password.path;
  };
  users.groups.ubuntu.gid = 1001;

  environment.systemPackages = [ pkgs.rsync ]; # the server side rrsync execs
}
