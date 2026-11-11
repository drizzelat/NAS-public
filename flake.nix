# The NAS (live since the PLT-1 cutover) and the A1 (not deployed yet); docs/nixos-host.md.
# Build without touching any host: nix build .#nixosConfigurations.<nas|a1>.config.system.build.toplevel
{
  description = "NAS estate — NixOS host configurations";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      agenix,
      disko,
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

      # Oracle Ampere A1, aarch64. Installed with nixos-anywhere, which runs disko.
      nixosConfigurations.a1 = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        modules = [
          agenix.nixosModules.default
          disko.nixosModules.disko
          ./hosts/a1
        ];
      };

      checks.x86_64-linux.nas-pools = import ./hosts/nas/test.nix {
        pkgs = nixpkgs.legacyPackages.x86_64-linux;
        inherit agenix;
      };

      formatter.x86_64-linux = nixpkgs.legacyPackages.x86_64-linux.nixfmt;
    };
}
