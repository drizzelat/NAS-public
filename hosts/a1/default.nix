# The Oracle Ampere A1 (tailnet a1-matrix) as NixOS, live since 2026-11-10; it pulls main itself
# (deploy.nix). Install: docs/runbooks/setup-operations/a1-nixos-cutover.md. Modules: docs/nixos-host.md.
{ lib, ageSecret, ... }:
{
  imports = [
    ../common
    ./hardware.nix
    ./network.nix
    ./users.nix
    ./jobs.nix
    ./deploy.nix
  ];

  networking.hostName = "a1-instance"; # Oracle's instance name, kept
  time.timeZone = "UTC"; # os-updates.md and the timer slots assume a UTC host clock

  age.secrets = lib.mkMerge [
    (ageSecret "a1-healthchecks-ping-url" { })
    (ageSecret "a1-ubuntu-password" { })
    (ageSecret "a1-deploy-key" { }) # read-only GitHub deploy key for deploy.nix
    # The NAS's ntfy topic, renamed to `ntfy-url` so it lands at /run/agenix/ntfy-url, where
    # nas-notify reads it. Never set `path` under /run/agenix: agenix then makes /run/agenix a
    # directory, can't link it to its generation, and no secret is reachable (cutover, 2026-11-10).
    (lib.mapAttrs' (_: lib.nameValuePair "ntfy-url") (ageSecret "a1-ntfy-url" { }))
  ];

  services.fail2ban.enable = true; # the sshd jail; bans go to nftables

  # Pin the state version at first install; never bump it afterwards.
  system.stateVersion = "26.05";
}
