# The NAS host (PLT-1), live since the cutover; docs/nixos-host.md. Build without touching any host:
#   nix build .#nixosConfigurations.nas.config.system.build.toplevel
#   nixos-rebuild build-vm --flake .#nas     # QEMU VM, no real pools/disks
{
  description = "NAS estate — NixOS host configurations";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      agenix,
      ...
    }:
    {
      nixosConfigurations.nas = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          agenix.nixosModules.default
          ./hosts/nas
        ];
      };

      checks.x86_64-linux.nas-pools = import ./hosts/nas/test.nix {
        pkgs = nixpkgs.legacyPackages.x86_64-linux;
        inherit agenix;
      };

      formatter.x86_64-linux = nixpkgs.legacyPackages.x86_64-linux.nixfmt;
    };
}
