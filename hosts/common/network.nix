# nftables firewall and native tailscaled. Each host adds its ports and its `tailscale set` flags.
{ config, ... }:
{
  networking.nftables.enable = true;
  networking.firewall = {
    enable = true;
    # The tailnet ACL decides who gets in over tailscale0.
    trustedInterfaces = [ "tailscale0" ];
  };

  services.tailscale = {
    enable = true;
    openFirewall = true;
  };
  # Otherwise tailscaled may pick iptables-legacy next to Docker's iptables-nft rules.
  systemd.services.tailscaled.environment.TS_DEBUG_FIREWALL_MODE = "nftables";

  assertions = [
    {
      assertion = !config.networking.nftables.flushRuleset;
      message = "flushRuleset would wipe Docker's and tailscaled's nftables tables on every reload";
    }
  ];
}
