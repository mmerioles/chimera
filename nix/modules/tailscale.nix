{ config, ... }:

# ------------------------------------------------------------
# Tailscale.
#
# Every VM runs DHCP and the leases move, so LAN addresses are not something
# worth writing down. Joining the tailnet gives each host a stable MagicDNS
# name matching networking.hostName - nix01, nix02, mon01 - the way tet01
# already has one.
# ------------------------------------------------------------

{
  services.tailscale = {
    enable = true;
    openFirewall = true;

    # Without this, every new host needs someone to run `tailscale up` and
    # click a login link by hand, which is the one step that would not survive
    # rebuilding this fleet from scratch. With it, a fresh VM authenticates
    # itself on first boot and comes up under its own name unattended.
    #
    # This is a reusable auth key from the Tailscale admin console, so it
    # never goes in the repo. Ship it into the target at install time:
    #
    #   mkdir -p extra/var/lib/tailscale
    #   cp ~/.secrets/ts-authkey extra/var/lib/tailscale/authkey
    #   chmod 600 extra/var/lib/tailscale/authkey
    #   nixos-anywhere --flake .#nix01 --extra-files extra ...
    #
    # Hosts that already joined are unaffected - the autoconnect unit only
    # runs `up` when the daemon reports NeedsLogin - and the node key persists
    # in /var/lib/tailscale across rebuilds, so this is read once per machine.
    authKeyFile = "/var/lib/tailscale/authkey";

    # Pin the tailnet name to the host name rather than letting it be derived,
    # so a rebuilt host reclaims the same name instead of becoming nix01-1.
    extraUpFlags = [ "--hostname=${config.networking.hostName}" ];
  };

  networking.firewall = {
    # Reaching a service over the tailnet should not require opening that port
    # to the whole LAN. With this, per-service LAN holes can be closed and the
    # tailnet becomes the way in.
    trustedInterfaces = [ "tailscale0" ];

    # Strict reverse-path filtering drops Tailscale's UDP traffic, which can
    # arrive on a different interface than the route table expects.
    checkReversePath = "loose";
  };
}
