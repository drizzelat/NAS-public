# The NAS as NixOS (PLT-1), live since the cutover. docs/nixos-host.md lists the modules,
# docs/runbooks/setup-operations/nixos-cutover.md the cutover and its rollback.
{ ... }:
{
  imports = [
    ./hardware.nix
    ./secrets.nix
    ./alerting.nix
    ./storage.nix
    ./network.nix
    ./users.nix
    ./samba.nix
    ./docker.nix
    ./backup.nix
    ./monitoring.nix
    ./power.nix
    ./gpu.nix
    ./vm.nix
    ./timers.nix
    ./deploy.nix
    ./health-probe.nix
    ./vm-variant.nix
  ];

  networking.hostName = "truenas";
  time.timeZone = "Europe/Berlin"; # kept from TrueNAS; timers.nix OnCalendar times are local
  i18n.defaultLocale = "en_US.UTF-8";

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  # TrueNAS shipped SystemMaxUse=50M: a file capped at ~6 MB and a rotation every ~13 min.
  # The journal is on the ext4 boot SSD here (never on ZFS: journald-zil-deadlock).
  services.journald.extraConfig = ''
    SystemMaxUse=2G
    SystemMaxFileSize=128M
    MaxRetentionSec=1month
  '';

  # Pin the state version at first install; never bump it afterwards.
  system.stateVersion = "26.05";
}
