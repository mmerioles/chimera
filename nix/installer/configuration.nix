{ modulesPath, ... }:

{
  imports = [
    "${modulesPath}/installer/cd-dvd/installation-cd-minimal.nix"
  ];

  networking.useDHCP = true;

  services.openssh = {
    enable = true;

    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  users.users.nixos.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIP193fLq/J/V8/vBpEqQCSqW+UUbfC+sflm9OEpno9Hm matthewmerioles@yahoo.com"
  ];

  system.stateVersion = "26.05";
}