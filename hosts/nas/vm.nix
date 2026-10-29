# Runner VM (docs/runbooks/setup-operations/runner-vm.md) under libvirt, as TrueNAS ran it:
# 2 vCPU, 2 GiB, UEFI, host-passthrough, zvol apps/runner-vm, virtio NIC on br0. The MAC
# (FritzBox DHCP reservation for .34) comes from agenix, so it stays out of git.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  virsh = "${config.virtualisation.libvirtd.package}/bin/virsh";
  domain = pkgs.writeText "runnervm.xml" ''
    <domain type='kvm'>
      <name>runnervm</name>
      <uuid>00bf5c03-dfc8-4d97-9ef1-3a80e89d538c</uuid><!-- pinned: a redefine with a new one fails -->
      <memory unit='MiB'>2048</memory>
      <vcpu placement='static'>2</vcpu>
      <os firmware='efi'>
        <type arch='x86_64' machine='q35'>hvm</type>
        <firmware><feature enabled='no' name='secure-boot'/></firmware>
        <boot dev='hd'/>
      </os>
      <features><acpi/><apic/></features>
      <cpu mode='host-passthrough' check='none' migratable='off'>
        <topology sockets='1' dies='1' cores='2' threads='1'/>
      </cpu>
      <clock offset='utc'/>
      <on_poweroff>destroy</on_poweroff>
      <on_reboot>restart</on_reboot>
      <on_crash>restart</on_crash>
      <devices>
        <disk type='block' device='disk'>
          <driver name='qemu' type='raw' cache='none' io='native' discard='unmap'/>
          <source dev='/dev/zvol/apps/runner-vm'/>
          <target dev='vda' bus='virtio'/>
        </disk>
        <interface type='bridge'>
          <mac address='@MAC@'/>
          <source bridge='br0'/>
          <model type='virtio'/>
        </interface>
        <serial type='pty'><target port='0'/></serial>
        <console type='pty'><target type='serial' port='0'/></console>
        <channel type='unix'><target type='virtio' name='org.qemu.guest_agent.0'/></channel>
        <memballoon model='virtio'/>
        <rng model='virtio'><backend model='random'>/dev/urandom</backend></rng>
      </devices>
    </domain>
  '';
in
{
  virtualisation.libvirtd = {
    enable = true;
    allowedBridges = [ "br0" ];
    onBoot = "ignore"; # runnervm.service starts it once the pool and the MAC are there
    onShutdown = "shutdown"; # ACPI shutdown on host shutdown, not a managed save
    shutdownTimeout = 120;
  };

  systemd.services.runnervm = {
    description = "Define and start the runner VM (libvirt domain runnervm)";
    after = [
      "libvirtd.service"
      "nas-pools.target"
      "zfs-volumes.target"
      "network-online.target"
    ];
    requires = [
      "libvirtd.service"
      "nas-pools.target"
    ];
    wants = [
      "zfs-volumes.target"
      "network-online.target"
    ];
    wantedBy = [ "multi-user.target" ];
    onFailure = [ "notify-failure@%n.service" ];
    restartIfChanged = false;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -eu
      mac_file=${config.age.secrets.runner-vm-mac.path or "/run/agenix/runner-vm-mac"}
      [ -r "$mac_file" ] || { echo "$mac_file missing: no MAC, not starting (DHCP reservation)"; exit 1; }
      mac=$(tr -d '[:space:]' < "$mac_file")
      [ -e /dev/zvol/apps/runner-vm ] || { echo "zvol apps/runner-vm missing"; exit 1; }
      sed "s/@MAC@/$mac/" ${domain} > /run/runnervm.xml
      ${virsh} define /run/runnervm.xml
      rm -f /run/runnervm.xml
      ${virsh} domstate runnervm | grep -q running || ${virsh} start runnervm
    '';
    preStop = "${virsh} shutdown runnervm || true";
  };
}
