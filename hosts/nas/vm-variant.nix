# Only for `nixos-rebuild build-vm` / `.config.system.build.vm`: a console-driven stand-in
# for test.nix when the test driver is not in the store. Three scratch disks for pools
# apps/data, root with an empty password on the serial console, no hardware or network services.
# Disks persist across boots when run with TMPDIR=<dir> USE_TMPDIR=1.
{ lib, ... }:
{
  virtualisation.vmVariant = {
    virtualisation = {
      memorySize = 3072;
      cores = 2;
      emptyDiskImages = [
        512
        512
        512
      ];
    };
    users.users.root.hashedPassword = ""; # empty password, this throwaway VM only
    services.smartd.enable = lib.mkForce false;
    power.ups.enable = lib.mkForce false;
    services.tailscale.enable = lib.mkForce false;
    systemd.services.runnervm.wantedBy = lib.mkForce [ ];
  };
}
