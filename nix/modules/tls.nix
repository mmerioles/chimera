{ ... }:

# ------------------------------------------------------------
# TLS.
#
# Browsers only trust https:// when the certificate names the host you
# typed. No public CA will issue for a bare tailnet name like `mon01`, which
# is why http://mon01:3000 is stuck at "Not secure" forever - the port is not
# the problem, the missing certificate is.
#
# merionas.com is a name we own, so hosts answer to <host>.merionas.com and
# nginx terminates TLS with a Let's Encrypt certificate for it.
#
# The challenge is DNS-01, not HTTP-01, and that choice is load-bearing:
# HTTP-01 requires Let's Encrypt to reach port 80 on the host from the
# public internet, which would mean opening these boxes to the world. DNS-01
# proves ownership by writing a TXT record at Cloudflare instead, so the
# certificate is issued to a host that stays entirely behind the tailnet.
# ------------------------------------------------------------

{
  security.acme = {
    acceptTerms = true;

    defaults = {
      # Expiry warnings land here. Anything deliverable works.
      email = "matthewmerioles@yahoo.com";

      dnsProvider = "cloudflare";

      # A Cloudflare API token scoped to Zone:DNS:Edit + Zone:Zone:Read on
      # merionas.com, as CF_DNS_API_TOKEN=... on one line. Generated at
      # https://dash.cloudflare.com/profile/api-tokens and planted on the box
      # by hand - it is a credential and never goes in the repo, the same way
      # the Tailscale auth key does not. Without this file the acme units
      # fail at startup with a lego "no credentials" error.
      environmentFile = "/var/lib/secrets/cloudflare.env";

      # Ask Cloudflare directly whether the challenge record has propagated.
      # The host's own resolver is Tailscale's MagicDNS at 100.100.100.100,
      # which forwards and caches, and a cached negative answer stalls the
      # propagation check until it times out.
      dnsResolver = "1.1.1.1:53";
    };
  };


  # ------------------------------------------------------------
  # nginx
  #
  # Deliberately no firewall hole for 443. Both nginx and the services it
  # fronts listen on 0.0.0.0, but tailscale0 is the only trusted interface
  # (see modules/tailscale.nix), so the tailnet reaches them and the LAN does
  # not. Being on the tailnet stays the authentication step.
  # ------------------------------------------------------------

  services.nginx = {
    enable = true;

    recommendedTlsSettings = true;
    recommendedProxySettings = true;
    recommendedOptimisation = true;
    recommendedGzipSettings = true;
  };
}
