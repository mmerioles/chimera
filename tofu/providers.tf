terraform {
  required_providers {
    proxmox = {
      source = "bpg/proxmox"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.25"
    }
    grafana = {
      source  = "grafana/grafana"
      version = "~> 4.46"
    }
  }
}

provider "proxmox" {
  endpoint = "https://tet01:8006/"
  insecure = true

  # The API cannot upload cloud-init snippets, so the provider copies them
  # over SSH. This is only exercised by doc01. Uses the key already in your
  # ssh-agent - the same one `ssh root@tet01` uses.
  ssh {
    agent    = true
    username = "root"

    node {
      name    = "tet01"
      address = "tet01"
    }
  }
}

# For doc01-tunnel.tf. Required for every plan now that the tunnel is in
# state - a missing file fails fast here with the path in the error, instead
# of as an opaque "failed to make http request" from the cloudflare data
# source. How to make the token: README, "public url".
provider "cloudflare" {
  api_token = trimspace(file(pathexpand("~/.secrets/cf-bordgame-token")))
}

# For doc01-grafana.tf. Talks to grafana on doc01 as admin, so dashboards and
# datasources are pushed by `tofu apply` instead of being baked into cloud-init
# (which would mean a VM rebuild per dashboard edit). Goes through the public
# URL rather than the tailnet on purpose: it is TLS end to end, and it is the
# one address that survives a rebuild - a fresh doc01 comes back with a new
# tailscale IP and, until the stale node is deleted, a new name.
provider "grafana" {
  url  = "https://mon.bordgame.app"
  auth = "admin:${trimspace(file(pathexpand("~/.secrets/doc01-grafana-password")))}"
}
