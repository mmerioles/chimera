{ pkgs, ... }:

{
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  boot.initrd.availableKernelModules = [
    "virtio_pci"
    "virtio_scsi"
    "sd_mod"
  ];

  networking.hostName = "metrics01";
  networking.useDHCP = true;

  services.openssh = {
    enable = true;

    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  virtualisation.docker.enable = true;

  virtualisation.oci-containers = {
    backend = "docker";

    containers.influxdb = {
      image = "influxdb:3.11.0-core";

      ports = [
        "8086:8181"
      ];

      volumes = [
        "/var/lib/influxdb3:/var/lib/influxdb3"
      ];

      extraOptions = [
        "--restart=unless-stopped"
      ];
    };
  };

  services.grafana = {
    enable = true;

    settings.server = {
      http_addr = "0.0.0.0";
      http_port = 3000;
    };
  };

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

  networking.firewall.allowedTCPPorts = [
    3000
    8086
  ];

  security.sudo.wheelNeedsPassword = false;

  system.stateVersion = "25.11";
}