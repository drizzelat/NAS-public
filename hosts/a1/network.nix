# docs/network.md → Cloud hosts. IPv4 by DHCP from OCI, the two VNIC IPv6 addresses static
# (the NTP pool lists them), default v6 route from RA. Public ports: docs/services/a1-vps-*.md.
{ ... }:
{
  networking.useNetworkd = true;
  networking.useDHCP = false;
  networking.tempAddresses = "disabled"; # as the Ubuntu image: no privacy addresses next to the NTP ones
  services.resolved.enable = true; # DNS is OCI's 169.254.169.254, from DHCP

  systemd.network = {
    enable = true;
    # Match the driver, not Type=ether: Docker's veths are ether too.
    networks."10-uplink" = {
      matchConfig.Driver = "virtio_net";
      networkConfig = {
        DHCP = "ipv4";
        IPv6AcceptRA = true;
      };
      address = [
        "2001:db8:1::20/64"
        "2001:db8:1::21/64"
      ];
      linkConfig = {
        MTUBytes = "9000";
        RequiredForOnline = "routable";
      };
    };
  };

  networking.firewall = {
    # Docker-published ports: IPv4 is DNATed past this chain, but IPv6 lands on docker-proxy (no
    # Docker IPv6), so it needs them here. sshd opens its own port; tailscale0 is trusted.
    allowedTCPPorts = [
      80 # a1-caddy
      443 # a1-caddy, WebTunnel
      4443 # Tor obfs4
      9443 # Tor ORPort
    ];
    allowedUDPPorts = [
      123 # chrony, host network (a1-vps-ntp); OCI Security List rules are stateless for it
    ];
  };

  services.tailscale = {
    useRoutingFeatures = "client"; # --accept-routes: reach the NAS LAN via its subnet route
    extraSetFlags = [
      "--hostname=a1-matrix"
      "--accept-routes"
      "--accept-dns=false" # MagicDNS broke every lookup and pull (a1-host-facts)
      "--ssh" # on today; the tailnet ACL blocks it, so admin SSH uses the public IP
    ];
  };

  services.openssh = {
    ports = [ 2222 ];
    openFirewall = true;
  };
}
