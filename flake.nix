{
  description = "chimera compute";

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
          ./nix/hosts/nix01/disk-config.nix
          ./nix/hosts/nix01/configuration.nix
          ./nix/modules/tailscale.nix
        ];
      };

      nix02 = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";

        modules = [
          disko.nixosModules.disko
          ./nix/hosts/nix02/disk-config.nix
          ./nix/hosts/nix02/configuration.nix
          ./nix/modules/tailscale.nix
        ];
      };

      mon01 = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";

        modules = [
            disko.nixosModules.disko
            ./nix/hosts/mon01/disk-config.nix
            ./nix/hosts/mon01/configuration.nix
            ./nix/hosts/mon01/health.nix
            ./nix/modules/tailscale.nix
            ./nix/modules/tls.nix
        ];
      };

      installer = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";

        modules = [
          ./nix/installer/configuration.nix
        ];
      };
    };
  };
}