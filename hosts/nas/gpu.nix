# QuickSync (N100 UHD, /dev/dri/card0 + renderD128 per the facts) for Jellyfin and Immich.
# The containers bring their own VA-API drivers; the host ones serve intel_gpu_top/vainfo.
{ lib, pkgs, ... }:
{
  hardware.graphics = {
    enable = true;
    extraPackages = [
      pkgs.intel-media-driver
      pkgs.vpl-gpu-rt
    ];
  };

  # renderD128 is world-accessible (systemd udev, MODE 0666), so QuickSync works for any
  # container uid. The gids still match TrueNAS, because stacks/immich group_adds 44 and 107.
  users.groups.video.gid = lib.mkForce 44;
  users.groups.render.gid = lib.mkForce 107;

  environment.systemPackages = [ pkgs.intel-gpu-tools ];
}
