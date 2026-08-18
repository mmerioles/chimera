{
  description = "chimera datacenter";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, disko, ... }: {
    nixosConfigurations = {
      nix01 = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";

        modules = [
          disko.nixosModules.disko
          ./hosts/nix01/disk-config.nix
          ./hosts/nix01/configuration.nix
        ];
      };

      installer = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";

        modules = [
          ./installer/configuration.nix
        ];
      };
    };
  };
}