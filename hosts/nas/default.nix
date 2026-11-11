# The NAS as NixOS (PLT-1), live since the cutover. docs/nixos-host.md lists the modules,
# docs/runbooks/setup-operations/nixos-cutover.md the cutover and its rollback.
{ ... }:
{
  imports = [
    ../common
    ./hardware.nix
    ./secrets.nix
    ./alerting.nix
    ./storage.nix
    ./network.nix
    ./users.nix
    ./samba.nix
    ./docker.nix
    ./backup.nix
    ./replica.nix
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

  # Pin the state version at first install; never bump it afterwards.
  system.stateVersion = "26.05";
}
