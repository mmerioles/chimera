# ------------------------------------------------------------
# What grafana on doc01 shows: the bord app, read from its Supabase project.
#
# The datasource is a read-only Postgres role on the hosted project, reached
# through Supabase's session pooler (the direct db host is IPv6-only on the
# free tier; the pooler is IPv4). The role is created once by
# ../doc01/grafana/bord-reader.sql - see README "bord dashboard".
#
# Dashboards are generated JSON in ../doc01/grafana/dashboards, pushed through
# grafana's API. Edit the generator, re-run it, `tofu apply`. UI edits get
# overwritten on the next apply, on purpose.
# ------------------------------------------------------------

locals {
  bord_db = {
    project = "polxedjpnuewjcuxhkzw"
    host    = "aws-0-ca-central-1.pooler.supabase.com:5432"
    name    = "postgres"
    role    = "grafana_ro"
  }
}

resource "grafana_folder" "bord" {
  title = "bord"
  uid   = "bord"

  depends_on = [proxmox_virtual_environment_vm.doc01]
}

resource "grafana_data_source" "bord" {
  type = "grafana-postgresql-datasource"
  name = "bord (supabase)"
  uid  = "bord-supabase"

  url           = local.bord_db.host
  database_name = local.bord_db.name
  # Supavisor routes by the tenant suffix on the user name.
  username = "${local.bord_db.role}.${local.bord_db.project}"

  json_data_encoded = jsonencode({
    sslmode         = "require"
    postgresVersion = 1700
    timescaledb     = false
    maxOpenConns    = 4
    maxIdleConns    = 2
    connMaxLifetime = 3600
  })

  secure_json_data_encoded = jsonencode({
    password = trimspace(file(pathexpand("~/.secrets/bord-grafana-db-password")))
  })

  depends_on = [proxmox_virtual_environment_vm.doc01]
}

resource "grafana_dashboard" "bord" {
  folder      = grafana_folder.bord.uid
  config_json = file("${path.module}/../doc01/grafana/dashboards/bord.json")
  overwrite   = true

  depends_on = [grafana_data_source.bord]
}

output "doc01_bord_dashboard" {
  value = grafana_dashboard.bord.url
}
