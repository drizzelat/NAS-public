# Shared by every NixOS host in the flake (hosts/nas, hosts/a1). Ports, flags and paths that
# differ per host stay in the host's own modules. docs/nixos-host.md.
{ ... }:
{
  imports = [
    ./base.nix
    ./alerting.nix
    ./secrets.nix
    ./network.nix
    ./ssh.nix
    ./docker.nix
  ];
}
