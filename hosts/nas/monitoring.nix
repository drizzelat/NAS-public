# OBS-2 host exporters, reachable from the container bridges (network.nix accepts br-* input).
# Not opened to the LAN. No node exporter: stacks/observability runs it on :9100, host network.
{ config, lib, ... }:
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
      # The default set asks for voltages the Eaton 3S does not report; ups.status is always exported.
      nutVariables = [
        "battery.charge"
        "battery.runtime"
        "ups.load"
        "ups.realpower"
        "ups.status"
      ];
      passwordPath = "/run/credentials/prometheus-nut-exporter.service/upsmon-password";
    };
  };

  # DynamicUser cannot read the root-only agenix file; systemd hands it over as a credential.
  systemd.services.prometheus-nut-exporter.serviceConfig.LoadCredential =
    lib.mkIf config.power.ups.enable
      [
        "upsmon-password:${config.power.ups.users.upsmon.passwordFile}"
      ];
}
