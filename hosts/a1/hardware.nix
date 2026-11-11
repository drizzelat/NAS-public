# OCI VM.Standard.A1.Flex: UEFI, virtio-scsi disks, virtio-net. disko lays out the boot volume
# only; the 100 GB data volume (label `matrix`) keeps its filesystem and is mounted below.
{ modulesPath, ... }:
{
  imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];

  boot.loader.systemd-boot.enable = true;
  # OCI firmware boots \EFI\BOOT\BOOTAA64.EFI from the boot volume; no NVRAM entry needed.
  boot.loader.efi.canTouchEfiVariables = false;

  boot.initrd.availableKernelModules = [
    "xhci_pci"
    "usbhid"
    "sd_mod"
  ];
  boot.kernelParams = [
    "console=tty1"
    "console=ttyAMA0" # last = /dev/console: the OCI serial console, the break-glass
  ];

  # LUN 0 is the boot volume, LUN 1 (0:0:1:1) the data volume. Detach the data volume before
  # installing anyway (cutover runbook): /dev/sdX order is not stable on OCI.
  disko.devices.disk.boot = {
    type = "disk";
    device = "/dev/disk/by-path/pci-0000:18:00.0-scsi-0:0:0:1";
    content = {
      type = "gpt";
      partitions = {
        ESP = {
          size = "512M";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = [
              "fmask=0077"
              "dmask=0077"
            ];
          };
        };
        root = {
          size = "100%";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
          };
        };
      };
    };
  };

  # By label, never /dev/oracleoci/oraclevd* (a1-host-facts). A failed mount keeps Docker down
  # instead of letting it write onto the boot disk; nofail keeps sshd reachable.
  fileSystems."/opt/matrix" = {
    device = "/dev/disk/by-label/matrix";
    fsType = "ext4";
    options = [
      "nofail"
      "x-systemd.required-by=docker.service"
      "x-systemd.before=docker.service"
    ];
  };
}
