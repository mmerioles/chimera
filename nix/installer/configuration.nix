{ modulesPath, ... }:

{
  imports = [
    "${modulesPath}/installer/cd-dvd/installation-cd-minimal.nix"
  ];

  services.openssh = {
    enable = true;

    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  users.users.nixos.openssh.authorizedKeys.keyFiles = [
    ../../keys/chimera_provision.pub
  ];

  system.stateVersion = "26.05";
}