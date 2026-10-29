# Docker as TrueNAS configured it (daemon.json), with data-root on a fresh apps/docker
# dataset (Phase 3 step 2). komodo-periphery stays compose, applied by the periphery-update timer.
{ pkgs, ... }:
let
  staticCompose = pkgs.docker-compose.overrideAttrs (o: {
    env = (o.env or { }) // {
      CGO_ENABLED = "0";
    };
  });
in
{
  virtualisation.docker = {
    enable = true;
    storageDriver = "overlay2";
    logDriver = "json-file"; # TrueNAS default; journald would take every container's logs
    daemon.settings = {
      data-root = "/mnt/apps/docker";
      ipv6 = true;
      fixed-cidr-v6 = "fdd0::/64";
      default-address-pools = [
        {
          base = "172.17.0.0/12";
          size = 24;
        }
        {
          base = "fdd0::/48";
          size = 64;
        }
      ];
      default-network-opts.bridge."com.docker.network.enable_ipv6" = "true";
      iptables = true;
      # Keep FORWARD at ACCEPT even if dockerd enables forwarding itself: the tailnet
      # subnet route and the runner VM on br0 are forwarded through this host.
      ip-forward-no-drop = true;
      live-restore = false;
    };
  };

  # The boot guard, declared: dockerd never starts on an empty /mnt/apps/docker.
  systemd.services.docker = {
    after = [ "nas-pools.target" ];
    requires = [ "nas-pools.target" ];
    onFailure = [ "notify-failure@%n.service" ];
    unitConfig.AssertPathIsMountPoint = "/mnt/apps/docker";
  };

  # stacks/nas-periphery mounts the host's compose plugin over the image's own. The store binary
  # needs /nix/store inside the container, so the mount gets a static build of the same compose.
  systemd.tmpfiles.rules = [
    "d /usr/libexec/docker/cli-plugins 0755 root root -"
    "L+ /usr/libexec/docker/cli-plugins/docker-compose - - - - ${staticCompose}/libexec/docker/cli-plugins/docker-compose"
  ];
}
