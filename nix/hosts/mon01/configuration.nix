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

    # LAN-facing holes only. nginx (443), ingest (8000) and InfluxDB
    # (8181) are deliberately absent: they are reached over the tailnet,
    # where tailscale0 is a trusted interface. SSH stays open as the way
    # back in if Tailscale is ever the thing that is broken.
    #
    # Grafana is not listed because it no longer listens off-box at all -
    # nginx reaches it on loopback.
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
        # Loopback, not 0.0.0.0. nginx is the only thing that talks to
        # Grafana now, and it does so over lo - leaving 3000 on the tailnet
        # would keep a plaintext door open beside the TLS one.
        http_addr = "127.0.0.1";
        http_port = 3000;

        # Grafana builds its own redirect and asset URLs from this. Left at
        # the default it emits http://localhost:3000 links behind a proxy,
        # which breaks login and every share link.
        domain = "mon01.merionas.com";
        root_url = "https://mon01.merionas.com/";
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
  # https://mon01.merionas.com
  #
  # See modules/tls.nix for the certificate machinery. enableACME requests
  # this exact name over DNS-01; forceSSL adds the :80 -> :443 redirect so
  # typing the bare hostname still lands somewhere trusted.
  #
  # mon01.merionas.com must be an A record at Cloudflare pointing at this
  # host's tailnet address, 100.123.4.125, and it must be DNS-only (grey
  # cloud). Proxying it orange breaks both halves: Cloudflare cannot route to
  # a 100.64/10 address, and it would terminate TLS itself with a
  # certificate we do not control.
  # ------------------------------------------------------------

  services.nginx.virtualHosts."mon01.merionas.com" = {
    enableACME = true;
    forceSSL = true;

    locations."/" = {
      proxyPass = "http://127.0.0.1:3000";

      # Grafana's Explore and live panels use websockets, which do not
      # survive a plain proxy_pass without the upgrade headers.
      proxyWebsockets = true;
    };
  };


  # ------------------------------------------------------------
  # NixOS
  # ------------------------------------------------------------

  system.stateVersion = "25.11";
}

