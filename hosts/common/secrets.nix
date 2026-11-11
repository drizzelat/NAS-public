# agenix on the age vault: host secrets live in secrets.enc/nixos/, encrypted to the vault key
# and each host's SSH key (recipients: secrets.enc/nixos/secrets.nix). Hosts declare theirs with
# `ageSecret`; a secret whose .age file is not committed yet is not declared, so builds never break.
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
in
{
  age.identityPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

  _module.args.ageSecret =
    name: attrs:
    lib.optionalAttrs (builtins.pathExists (dir + "/${name}.age")) {
      ${name} = {
        file = checked name;
      }
      // attrs;
    };
}
