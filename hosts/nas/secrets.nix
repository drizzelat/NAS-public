# agenix on the age vault: host secrets live in secrets.enc/nixos/, encrypted to the vault
# key and the host's SSH key (recipients: secrets.enc/nixos/secrets.nix). A secret whose
# .age file is not committed yet is simply not declared, so the build never breaks on it.
{ lib, pkgs, ... }:
let
  dir = ../../secrets.enc/nixos;
  # git may class a small .age file as text and CRLF it on a Windows checkout; fail the build
  # then, as agenix would skip the secret at boot (docs/nixos-host.md).
  checked =
    name:
    pkgs.runCommand "${name}.age" { src = dir + "/${name}.age"; } ''
      printf 'age-encryption.org/v1\n' > header
      if ! head -c 22 "$src" | cmp -s - header; then
        echo "${name}.age: header is not age v1 (CRLF from a Windows checkout?); copy with git archive" >&2
        exit 1
      fi
      cp "$src" "$out"
    '';
  secret =
    name: attrs:
    lib.optionalAttrs (builtins.pathExists (dir + "/${name}.age")) {
      ${name} = {
        file = checked name;
      }
      // attrs;
    };
in
{
  age.identityPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

  age.secrets = lib.mkMerge [
    # networkd drop-in with the MAC TrueNAS gave br0 (kept out of the public mirror). agenix
    # runs in initrd activation, before stage 2 starts networkd, so it is there when br0 is made.
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
