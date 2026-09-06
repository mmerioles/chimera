{ pkgs, ... }:

{
  # ------------------------------------------------------------
  # Boot
  # ------------------------------------------------------------

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  boot.initrd.availableKernelModules = [
    "virtio_pci"
    "virtio_scsi"
    "sd_mod"
  ];


  # ------------------------------------------------------------
  # Networking
  # ------------------------------------------------------------

  networking.hostName = "mon01";
  networking.useDHCP = true;

  networking.firewall = {
    enable = true;

    # LAN-facing holes only. Grafana (3000), ingest (8000) and InfluxDB
    # (8181) are deliberately absent: they are reached over the tailnet,
    # where tailscale0 is a trusted interface. SSH stays open as the way
    # back in if Tailscale is ever the thing that is broken.
    allowedTCPPorts = [
      22    # SSH
    ];
  };


  # ------------------------------------------------------------
  # SSH
  # ------------------------------------------------------------

  services.openssh = {
    enable = true;

    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
    };
  };


  # ------------------------------------------------------------
  # Users
  # ------------------------------------------------------------

  users.users.matt = {
    isNormalUser = true;

    extraGroups = [
      "wheel"
    ];

    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIP193fLq/J/V8/vBpEqQCSqW+UUbfC+sflm9OEpno9Hm matthewmerioles@yahoo.com"
    ];
  };

  security.sudo.wheelNeedsPassword = false;


  # ------------------------------------------------------------
  # Packages
  # ------------------------------------------------------------

  environment.systemPackages = with pkgs; [
    git
    vim
    curl
    htop
    influxdb3
  ];


  # ------------------------------------------------------------
  # InfluxDB 3 Core user/group
  # ------------------------------------------------------------

  users.groups.influxdb3 = {};

  users.users.influxdb3 = {
    isSystemUser = true;
    group = "influxdb3";
    home = "/var/lib/influxdb3";
  };

  

  # ------------------------------------------------------------
  # InfluxDB 3 Core
  # ------------------------------------------------------------

  systemd.tmpfiles.rules = [
    "d /var/lib/influxdb3 0750 influxdb3 influxdb3 -"
    "d /var/lib/influxdb3/data 0750 influxdb3 influxdb3 -"
  ];

  systemd.services.influxdb3 = {
    description = "InfluxDB 3 Core";

    wantedBy = [ "multi-user.target" ];

    wants = [
        "network-online.target"
    ];

    after = [
        "network-online.target"
        "var-lib-influxdb3.mount"
        "systemd-tmpfiles-setup.service"
    ];

    serviceConfig = {
        User = "influxdb3";
        Group = "influxdb3";

        ExecStart = ''
        ${pkgs.influxdb3}/bin/influxdb3 serve \
            --node-id mon01 \
            --object-store file \
            --data-dir /var/lib/influxdb3/data
        '';

        Restart = "on-failure";
        RestartSec = "5s";
        WorkingDirectory = "/var/lib/influxdb3";
    };
    };


  # ------------------------------------------------------------
  # Grafana secret
  #
  # Generate once and persist outside of the Nix store.
  # ------------------------------------------------------------

  systemd.services.grafana-secret = {
    description = "Generate Grafana secret key";

    wantedBy = [
      "multi-user.target"
    ];

    before = [
      "grafana.service"
    ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    script = ''
      install -d -m 0700 -o grafana -g grafana /var/lib/grafana

      if [ ! -f /var/lib/grafana/secret_key ]; then
        ${pkgs.openssl}/bin/openssl rand -hex 32 \
          > /var/lib/grafana/secret_key

        chown grafana:grafana /var/lib/grafana/secret_key
        chmod 0600 /var/lib/grafana/secret_key
      fi
    '';
  };


  # ------------------------------------------------------------
  # Grafana
  # ------------------------------------------------------------

  services.grafana = {
    enable = true;

    settings = {
      server = {
        http_addr = "0.0.0.0";
        http_port = 3000;
      };

      security = {
        secret_key = "$__file{/var/lib/grafana/secret_key}";
      };
    };
  };

  systemd.services.grafana = {
    requires = [
      "grafana-secret.service"
    ];

    after = [
      "grafana-secret.service"
    ];
  };


  # ------------------------------------------------------------
  # NixOS
  # ------------------------------------------------------------

  system.stateVersion = "25.11";
}

