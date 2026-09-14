{ config, pkgs, ... }:

# ------------------------------------------------------------
# Health dashboard, running natively.
#
# This is the docker-compose stack in health/ ported to systemd units, the
# same way influxdb3 was: Postgres/TimescaleDB, the FastAPI ingest API, and
# Grafana reading through a role that can only SELECT.
#
# The compose file's local-dev-only settings are deliberately absent here:
# no anonymous Grafana auth, and no default passwords. Every secret is
# generated on the box and lives outside /nix/store, which is world-readable.
# ------------------------------------------------------------

let
  # These reach outside nix/ into health/, which is why the flake root sits at
  # the repo root. Nix only copies files under the flake into the store, so
  # moving flake.nix back down to nix/ would break all three of these.
  ingestSrc  = ../../../health/ingest/app;
  migrations = ../../../health/db/migrations;
  dashboards = ../../../health/grafana/dashboards;

  # A day runs local-midnight to local-midnight everywhere, so the ingest
  # rollups and Grafana's display have to agree on one zone.
  localTimezone = "America/New_York";

  pythonEnv = pkgs.python312.withPackages (ps: with ps; [
    fastapi
    uvicorn
    # requirements.txt asks for uvicorn[standard] and psycopg[binary,pool];
    # pip extras have no Nix equivalent, so the extras are named out here.
    uvloop
    httptools
    websockets
    watchfiles
    psycopg
    psycopg-c
    psycopg-pool
    pydantic
  ]);

  # uvicorn is invoked as `app.main:app`, so `app` has to sit directly beneath
  # a directory on PYTHONPATH rather than being the directory itself.
  ingestRoot = pkgs.runCommand "health-ingest-src" { } ''
    mkdir -p $out
    cp -r ${ingestSrc} $out/app
  '';

  stateDir            = "/var/lib/health";
  secretsEnv          = "${stateDir}/secrets.env";
  grafanaPasswordFile = "${stateDir}/grafana_db_password";
  grafanaAdminFile    = "${stateDir}/grafana_admin_password";
in
{
  # ------------------------------------------------------------
  # Users
  # ------------------------------------------------------------

  users.groups.health = { };

  users.users.health = {
    isSystemUser = true;
    group = "health";
    home = stateDir;
  };

  time.timeZone = localTimezone;


  # ------------------------------------------------------------
  # Secrets
  #
  # Generated once and persisted outside the Nix store, matching the
  # grafana-secret pattern. Rotate by deleting the file and restarting.
  # ------------------------------------------------------------

  systemd.services.health-secrets = {
    description = "Generate health stack secrets";

    wantedBy = [ "multi-user.target" ];

    before = [
      "health-ingest.service"
      "grafana.service"
    ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    script = ''
      # 0751, not 0750: Grafana is not in the health group but has to traverse
      # this directory to stat the password file it does have access to. The
      # execute bit permits traversal without permitting a listing.
      install -d -m 0751 -o root -g health ${stateDir}

      if [ ! -f ${grafanaPasswordFile} ]; then
        ${pkgs.openssl}/bin/openssl rand -hex 32 > ${grafanaPasswordFile}
      fi

      # Grafana reads this file directly via $__file{}, so it needs the group.
      chown root:grafana ${grafanaPasswordFile}
      chmod 0640 ${grafanaPasswordFile}

      # Grafana is reachable on the LAN, so it does not get to keep the
      # admin/admin default that services.grafana ships with.
      if [ ! -f ${grafanaAdminFile} ]; then
        ${pkgs.openssl}/bin/openssl rand -base64 24 | tr -d '\n' > ${grafanaAdminFile}
      fi

      chown root:grafana ${grafanaAdminFile}
      chmod 0640 ${grafanaAdminFile}

      if [ ! -f ${secretsEnv} ]; then
        echo "INGEST_TOKEN=$(${pkgs.openssl}/bin/openssl rand -hex 32)" > ${secretsEnv}
      fi

      # The ingest service provisions the read-only role from this value, so it
      # has to agree with what Grafana reads. Rewritten from the password file
      # on every start rather than kept as a second copy that can drift.
      ${pkgs.gnused}/bin/sed -i '/^GRAFANA_DB_PASSWORD=/d' ${secretsEnv}
      echo "GRAFANA_DB_PASSWORD=$(cat ${grafanaPasswordFile})" >> ${secretsEnv}

      chown root:health ${secretsEnv}
      chmod 0640 ${secretsEnv}
    '';
  };


  # ------------------------------------------------------------
  # Postgres + TimescaleDB
  #
  # Apache edition, not TSL: the schema only calls create_hypertable(), which
  # the Apache build provides, and it keeps the closure free of unfree code.
  # ------------------------------------------------------------

  services.postgresql = {
    enable = true;
    package = pkgs.postgresql_17;

    extensions = ps: with ps; [ timescaledb-apache ];

    settings = {
      shared_preload_libraries = "timescaledb";
      # Loopback only. Grafana's postgres datasource wants a host:port, so the
      # socket alone is not enough, but nothing off-box should reach 5432.
      listen_addresses = "localhost";
    };

    ensureDatabases = [ "health" ];

    ensureUsers = [
      { name = "health"; ensureDBOwnership = true; }
    ];

    authentication = pkgs.lib.mkAfter ''
      # Ingest connects over the unix socket as its own system user, so its
      # credentials are the uid rather than a password to be leaked.
      local health health     peer
      host  health grafana_ro 127.0.0.1/32 scram-sha-256
      host  health grafana_ro ::1/128      scram-sha-256
    '';
  };


  # ------------------------------------------------------------
  # Database bootstrap
  #
  # Two things the ingest service cannot do for itself, both needing
  # superuser: installing the extension, and being allowed to create the
  # read-only role it hands to Grafana.
  # ------------------------------------------------------------

  systemd.services.health-db-init = {
    description = "Bootstrap the health database";

    wantedBy = [ "multi-user.target" ];

    # ensureDatabases is applied by postgresql-setup, which itself runs after
    # postgresql.service. Ordering on postgresql.service alone races it and
    # lands here before the health database exists.
    requires = [ "postgresql.service" "postgresql-setup.service" ];

    after = [ "postgresql.service" "postgresql-setup.service" ];

    before = [ "health-ingest.service" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "postgres";
      Group = "postgres";
    };

    script = ''
      psql=${config.services.postgresql.package}/bin/psql

      # 0001_core.sql runs CREATE EXTENSION, which is superuser-only. Doing it
      # here first turns that statement into a no-op for the ingest user.
      $psql -d health -tAc "CREATE EXTENSION IF NOT EXISTS timescaledb"

      # ensure_readonly_role() issues CREATE ROLE on startup.
      $psql -tAc "ALTER ROLE health CREATEROLE"
    '';
  };


  # ------------------------------------------------------------
  # Ingest API
  # ------------------------------------------------------------

  systemd.services.health-ingest = {
    description = "Chimera health ingest API";

    wantedBy = [ "multi-user.target" ];

    wants = [ "network-online.target" ];

    requires = [
      "postgresql.service"
      "postgresql-setup.service"
      "health-secrets.service"
      # Without CREATEROLE granted here first, startup dies provisioning the
      # read-only role, so a failed bootstrap must hold ingest back.
      "health-db-init.service"
    ];

    after = [
      "network-online.target"
      "postgresql.service"
      "postgresql-setup.service"
      "health-secrets.service"
      "health-db-init.service"
    ];

    environment = {
      PYTHONPATH = "${ingestRoot}";
      PYTHONUNBUFFERED = "1";
      # Peer auth over the socket; no password in the connection string.
      DATABASE_URL = "postgresql://health@/health?host=/run/postgresql";
      MIGRATIONS_DIR = "${migrations}";
      LOCAL_TIMEZONE = localTimezone;
      GRAFANA_DB_USER = "grafana_ro";
    };

    serviceConfig = {
      User = "health";
      Group = "health";

      # Supplies INGEST_TOKEN and GRAFANA_DB_PASSWORD. systemd reads this as
      # root before dropping privileges.
      EnvironmentFile = secretsEnv;

      ExecStart = ''
        ${pythonEnv}/bin/uvicorn app.main:app \
          --host 0.0.0.0 \
          --port 8000
      '';

      Restart = "on-failure";
      RestartSec = "5s";

      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ReadWritePaths = [ "/run/postgresql" ];
    };
  };


  # ------------------------------------------------------------
  # Grafana provisioning
  #
  # Server/secret_key settings live in configuration.nix; this adds the
  # datasource and the dashboard, both from disk so UI edits stay disposable.
  # ------------------------------------------------------------

  services.grafana = {
    settings.date_formats.default_timezone = localTimezone;

    # Only consulted when Grafana initialises its admin for the first time;
    # an already-provisioned instance needs grafana-cli reset-admin-password.
    settings.security.admin_password = "$__file{${grafanaAdminFile}}";

    # Open the dashboard without logging in. This is only defensible because
    # Grafana is not reachable from the LAN - the firewall below leaves 3000
    # closed and the tailnet is what you have to be on to reach it at all.
    # Viewer, not Editor: anonymous visitors read, they do not edit.
    settings."auth.anonymous" = {
      enabled = true;
      org_name = "Main Org.";
      org_role = "Viewer";
    };

    provision = {
      enable = true;

      datasources.settings = {
        apiVersion = 1;

        datasources = [
          {
            name = "Health";
            uid = "health-postgres";
            type = "postgres";
            access = "proxy";
            url = "127.0.0.1:5432";
            database = "health";
            user = "grafana_ro";
            isDefault = true;
            editable = false;

            jsonData = {
              # Grafana 11+ moved the database name into jsonData. The
              # top-level `database` above is still read by the backend, which
              # is why API queries succeeded while the dashboard stayed blank:
              # the frontend plugin reads it from here, found nothing, and
              # refused to issue any query at all - "You do not currently have
              # a default database configured for this data source."
              database = "health";

              # Loopback to a socket-local Postgres; TLS here would only
              # protect traffic that never leaves the kernel.
              sslmode = "disable";
              postgresVersion = 1700;
              timescaledb = true;
            };

            # Read from disk so the password is not baked into /nix/store.
            secureJsonData.password = "$__file{${grafanaPasswordFile}}";
          }
        ];
      };

      dashboards.settings = {
        apiVersion = 1;

        providers = [
          {
            name = "chimera-health";
            orgId = 1;
            folder = "Health";
            type = "file";
            disableDeletion = false;
            allowUiUpdates = false;
            updateIntervalSeconds = 30;

            options = {
              path = "${dashboards}";
              foldersFromFilesStructure = false;
            };
          }
        ];
      };
    };
  };


  # ------------------------------------------------------------
  # Firewall
  #
  # Nothing is opened to the LAN. Ingest and Grafana both listen on 0.0.0.0,
  # but tailscale0 is a trusted interface (see modules/tailscale.nix) so the
  # tailnet reaches them and the LAN does not. That is what makes anonymous
  # Grafana and a token-only write path acceptable here: being on the tailnet
  # is the authentication step.
  #
  # The phone uploads over the tailnet too - it is a node on it already.
  # ------------------------------------------------------------
}
