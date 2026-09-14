# ------------------------------------------------------------
# Public URL for grafana on doc01: https://mon.bordgame.app
#
# A Cloudflare Tunnel. cloudflared on doc01 dials out to Cloudflare's edge
# and Cloudflare routes the hostname down that connection, so nothing is
# port-forwarded and doc01 keeps no inbound holes. Tofu creates the tunnel,
# its ingress rule, and the DNS record; the token it hands to cloud-init is
# the only thing the VM needs.
#
# Needs ~/.secrets/cf-bordgame-token - see README "public url".
# ------------------------------------------------------------

locals {
  tunnel = {
    zone                = "bordgame.app"
    hostname            = "mon.bordgame.app"
    cloudflared_version = "2026.9.1"
  }
}

data "cloudflare_zones" "bordgame" {
  name = local.tunnel.zone
}

locals {
  cf_zone_id    = data.cloudflare_zones.bordgame.result[0].id
  cf_account_id = data.cloudflare_zones.bordgame.result[0].account.id
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "doc01" {
  account_id = local.cf_account_id
  name       = "doc01"
  config_src = "cloudflare"
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "doc01" {
  account_id = local.cf_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.doc01.id

  config = {
    ingress = [
      {
        hostname = local.tunnel.hostname
        # Compose service name - cloudflared and grafana share the network.
        service = "http://grafana:3000"
      },
      {
        # Catch-all is mandatory; anything else on this tunnel gets a 404.
        service = "http_status:404"
      },
    ]
  }
}

resource "cloudflare_dns_record" "mon" {
  zone_id = local.cf_zone_id
  name    = local.tunnel.hostname
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.doc01.id}.cfargotunnel.com"
  proxied = true
  ttl     = 1
  comment = "grafana on doc01, via tunnel. managed by tofu."
}

data "cloudflare_zero_trust_tunnel_cloudflared_token" "doc01" {
  account_id = local.cf_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.doc01.id
}

output "doc01_public_url" {
  value = "https://${local.tunnel.hostname}"
}
