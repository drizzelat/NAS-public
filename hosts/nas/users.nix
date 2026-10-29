# UIDs/GIDs as on TrueNAS, so ownership on the pools holds. SMB passwords are set
# again with `smbpasswd -a` after install (TrueNAS keeps them in its database).
{
  config,
  lib,
  pkgs,
  nasHealthProbe,
  ...
}:
let
  # Public half of secrets/ssh/truenas_ed25519, the only key TrueNAS accepts for it.
  adminKeys = [
    "ssh-ed25519 <redacted> you@example.com"
  ];
in
{
  users.mutableUsers = false;
  programs.zsh.enable = true; # truenas_admin's shell
  users.allowNoPasswordLogin = adminKeys == [ ];

  # Keys come only from Nix; ~/.ssh/authorized_keys on the pools is ignored.
  services.openssh.authorizedKeysInHomedir = false;

  # Kept under its TrueNAS name: runbooks, CI and scripts all ssh as truenas_admin.
  users.users.truenas_admin = {
    uid = 950;
    isSystemUser = true;
    group = "truenas_admin";
    extraGroups = [
      "wheel"
      "docker"
    ];
    description = "Local Administrator";
    home = "/home/truenas_admin";
    createHome = true;
    shell = pkgs.zsh; # as on TrueNAS
    openssh.authorizedKeys.keys = adminKeys;
    # Console break-glass: a crypt hash from the vault, when the secret exists.
    hashedPasswordFile = lib.mkIf (
      config.age.secrets ? truenas-admin-password
    ) config.age.secrets.truenas-admin-password.path;
  };
  users.groups.truenas_admin.gid = 950;

  # TrueNAS built-in owner of app data (files, filebrowser, portainer, smb_share).
  users.users.apps = {
    uid = 568;
    isSystemUser = true;
    group = "apps";
  };
  users.groups.apps.gid = 568;

  # SMB-only accounts: no shell, no home. Note uid != gid on TrueNAS.
  users.users.user2 = {
    uid = 3001;
    isNormalUser = true;
    group = "user2";
    extraGroups = [ "nas_users" ];
    description = "user2";
    home = "/var/empty";
    createHome = false;
    shell = "${pkgs.shadow}/bin/nologin";
  };
  users.groups.user2.gid = 3000;

  users.users.user1 = {
    uid = 3002;
    isNormalUser = true;
    group = "user1";
    extraGroups = [ "nas_users" ];
    description = "user1";
    home = "/var/empty";
    createHome = false;
    shell = "${pkgs.shadow}/bin/nologin";
  };
  users.groups.user1.gid = 3001;

  users.groups.nas_users.gid = 3002;

  # nas-health-check CI: forced command, read-only verbs, no shell
  # (docs/runbooks/setup-operations/nas-health-check.md).
  users.users.nashealth = {
    uid = 3003;
    isNormalUser = true;
    group = "nashealth";
    description = "nas-health-check CI (forced command, read-only)";
    home = "/mnt/apps/nas-health";
    createHome = false; # on the apps pool; created by TrueNAS
    shell = pkgs.dash;
    openssh.authorizedKeys.keys = [
      ''command="${nasHealthProbe}",restrict ssh-ed25519 <redacted> nas-health-check CI -> nashealth@truenas (forced command)''
    ];
  };
  users.groups.nashealth.gid = 3003;

  security.sudo = {
    execWheelOnly = false; # nashealth's grants live in health-probe.nix
    wheelNeedsPassword = false; # TrueNAS: truenas_admin sudo ALL NOPASSWD
  };
}
