{ pkgs, ... }:

{
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  boot.initrd.availableKernelModules = [
  "virtio_pci"
  "virtio_scsi"
  "sd_mod"
  ];
  
  networking.hostName = "nix02";
  networking.useDHCP = true;

  services.openssh = {
    enable = true;

    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  virtualisation.docker.enable = true;

  users.users.matt = {
    isNormalUser = true;

    extraGroups = [
      "wheel"
      "docker"
    ];

    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIP193fLq/J/V8/vBpEqQCSqW+UUbfC+sflm9OEpno9Hm matthewmerioles@yahoo.com"
    ];
  };

  environment.systemPackages = with pkgs; [
    git
    vim
    curl
    htop
  ];

  security.sudo.wheelNeedsPassword = false;

  system.stateVersion = "25.11";
}