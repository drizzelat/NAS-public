# docs/network.md: LAN address on br0 over enp2s0, static, STP off; EEE off on enp2s0.
# The MAC TrueNAS gave br0 comes from an agenix drop-in (secrets.nix), not from git.
{ config, lib, ... }:
{
  networking.useNetworkd = true;
  networking.useDHCP = false;
  networking.domain = "nas.example.com"; # TrueNAS network.config domain
  networking.search = [ "nas.example.com" ];
  networking.nameservers = [
    "1.1.1.1"
    "192.168.1.111" # AdGuard on this host, second so DNS survives AdGuard being down
  ];
  services.resolved = {
    enable = true;
    settings.Resolve = {
      LLMNR = false;
      MulticastDNS = false;
    };
  };

  systemd.network = {
    enable = true;
    wait-online.anyInterface = true;

    # Pin the name by PCI path and switch EEE off (r8169 silent packet loss,
    # runbooks/incident-response/nas-nic-packet-loss.md). systemd >= 258.
    links."10-enp2s0" = {
      matchConfig.Path = "pci-0000:02:00.0";
      linkConfig.Name = "enp2s0";
      extraConfig = ''
        [EnergyEfficientEthernet]
        Enable=no
      '';
    };

    netdevs."10-br0" = {
      netdevConfig = {
        Name = "br0";
        Kind = "bridge";
      };
      bridgeConfig.STP = false;
    };

    networks."10-enp2s0" = {
      matchConfig.Name = "enp2s0";
      networkConfig = {
        Bridge = "br0";
        LinkLocalAddressing = "no";
      };
    };

    networks."20-br0" = {
      matchConfig.Name = "br0";
      address = [ "192.168.1.111/24" ];
      gateway = [ "192.168.1.1" ];
      # TrueNAS has ipv6_auto on br0: SLAAC from the FritzBox, as the facts show.
      networkConfig = {
        IPv6AcceptRA = true;
        ConfigureWithoutCarrier = true;
      };
      linkConfig.RequiredForOnline = "routable";
    };
  };

  networking.nftables.enable = true;
  networking.firewall = {
    enable = true;
    # Docker-published ports (53, 80, 443, 8443, 8120, 8090) are DNATed and never reach
    # this input chain. Host-network services and host daemons are listed here.
    allowedTCPPorts = [
      22 # sshd
      9998 # conduit metrics, host network
      9999 # snowflake metrics, host network
    ];
    allowedUDPPorts = [
      5353 # mDNS for Home Assistant discovery, host network
    ];
    # TrueNAS runs no host firewall and the tailnet ACL already decides who gets in.
    trustedInterfaces = [ "tailscale0" ];
    checkReversePath = "loose"; # subnet router: tailscaled policy-routes by fwmark
    # Containers reach host-network services and exporters over their bridge.
    # SSDP devices answer Home Assistant's multicast M-SEARCH from :1900, which conntrack can't match.
    extraInputRules = ''
      iifname "docker0" accept
      iifname "br-*" accept
      ip saddr 192.168.1.0/24 udp sport 1900 accept
    '';
  };

  # Native module instead of stacks/tailscale. Same state dir as the container, so the
  # node keeps its identity and tailnet IP (100.64.0.11, which the VPS peripheries allow).
  services.tailscale = {
    enable = true;
    useRoutingFeatures = "server";
    openFirewall = true;
    # The module passes --state=/var/lib/tailscale/...; the later flag wins.
    extraDaemonFlags = [
      "--state=/mnt/apps/tailscale/tailscaled.state"
      "--statedir=/mnt/apps/tailscale"
    ];
    extraSetFlags = [
      "--hostname=nas"
      "--advertise-routes=192.168.1.0/24"
      "--accept-dns=false"
      "--snat-subnet-routes=false"
    ];
  };
  systemd.services.tailscaled = {
    after = [ "nas-pools.target" ];
    requires = [ "nas-pools.target" ];
    unitConfig.RequiresMountsFor = [ "/mnt/apps/tailscale" ];
    # Same reason as the container: tailscaled otherwise may pick iptables-legacy.
    environment.TS_DEBUG_FIREWALL_MODE = "nftables";
  };

  # avahi stays off (no .local needed; see docs/network.md).
  services.avahi.enable = false;

  services.openssh = {
    enable = true;
    ports = [ 22 ];
    openFirewall = false; # port 22 is in allowedTCPPorts above
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
      AllowTcpForwarding = false; # TrueNAS ssh.config tcpfwd false
      X11Forwarding = false;
    };
  };

  assertions = [
    {
      assertion = !config.networking.nftables.flushRuleset;
      message = "flushRuleset would wipe Docker's and tailscaled's nftables tables on every reload";
    }
  ];
  boot.kernel.sysctl = {
    # TrueNAS values; ip_forward is set by useRoutingFeatures before dockerd starts, so
    # Docker leaves the FORWARD policy at ACCEPT (the runner VM on br0 needs that).
    "vm.swappiness" = lib.mkDefault 1;
    "vm.overcommit_memory" = 1;
    "fs.inotify.max_user_watches" = 251200;
  };
}
