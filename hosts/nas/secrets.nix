# The NAS's agenix secrets; `ageSecret` and the CRLF guard are in hosts/common/secrets.nix.
{ lib, ageSecret, ... }:
{
  age.secrets = lib.mkMerge [
    # networkd drop-in with the MAC TrueNAS gave br0 (kept out of the public mirror). agenix
    # runs in initrd activation, before stage 2 starts networkd, so it is there when br0 is made.
    (ageSecret "br0-mac.conf" {
      path = "/run/systemd/network/10-br0.netdev.d/mac.conf";
      mode = "0444";
    })
    (ageSecret "runner-vm-mac" { })
    (ageSecret "ntfy-url" { })
    (ageSecret "truenas-admin-password" { })
    (ageSecret "restic-password" { })
    (ageSecret "restic-ssh-key" { })
    (ageSecret "upsmon-password" { })
    (ageSecret "healthchecks-host-deploy-url" { })
  ];
}
