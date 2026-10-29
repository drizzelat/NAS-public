# agenix on the age vault: host secrets live in secrets.enc/nixos/, encrypted to the vault
# key and the host's SSH key (recipients: secrets.enc/nixos/secrets.nix). A secret whose
# .age file is not committed yet is simply not declared, so the build never breaks on it.
{ lib, ... }:
let
  dir = ../../secrets.enc/nixos;
  secret =
    name: attrs:
    lib.optionalAttrs (builtins.pathExists (dir + "/${name}.age")) {
      ${name} = {
        file = dir + "/${name}.age";
      }
      // attrs;
    };
in
{
  age.identityPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

  age.secrets = lib.mkMerge [
    # networkd drop-in with the MAC TrueNAS gave br0 (kept out of the public mirror).
    (secret "br0-mac.conf" {
      path = "/run/systemd/network/10-br0.netdev.d/mac.conf";
      mode = "0444";
    })
    (secret "runner-vm-mac" { })
    (secret "ntfy-url" { })
    (secret "truenas-admin-password" { })
    (secret "restic-password" { })
    (secret "restic-ssh-key" { })
    (secret "upsmon-password" { })
    (secret "healthchecks-host-deploy-url" { })
  ];
}
