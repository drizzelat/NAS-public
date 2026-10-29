# OBS-2 host exporters, reachable from the container bridges (network.nix accepts br-* input).
# Not opened to the LAN. No node exporter: stacks/observability runs it on :9100, host network.
{ config, ... }:
{
  services.prometheus.exporters = {
    zfs = {
      enable = true;
      port = 9134;
    };
    smartctl = {
      enable = true;
      port = 9633;
    };
    nut = {
      enable = config.power.ups.enable;
      port = 9199;
      nutUser = "upsmon";
      passwordPath = config.power.ups.users.upsmon.passwordFile;
    };
  };
}
