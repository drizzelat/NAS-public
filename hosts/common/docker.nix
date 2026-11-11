# Docker for Komodo-deployed stacks. data-root, IPv6 and address pools are per host.
{ ... }:
{
  virtualisation.docker = {
    enable = true;
    storageDriver = "overlay2";
    logDriver = "json-file"; # journald would take every container's logs
    daemon.settings = {
      iptables = true;
      live-restore = false;
    };
  };
}
