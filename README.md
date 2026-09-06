# Chimera Datacenter

Proxmox host `tet01` with three NixOS VMs on it.

| host  | what                                |
|-------|-------------------------------------|
| tet01 | proxmox                             |
| mon01 | health dashboard, grafana, influxdb |
| nix01 | nix builder                         |
| nix02 | docker box                          |

Everything is on Tailscale. Use hostnames, never IPs — the VMs get their
addresses from DHCP and they move.

Flake is at the repo root. Run everything from there.

## deploy

```
nix run nixpkgs#nixos-rebuild -- switch \
  --flake .#mon01 \
  --target-host matt@mon01 \
  --build-host matt@mon01 \
  --sudo
```

As `matt --sudo`, not root — root login is off on every host.

## rebuild the whole fleet

Tested: all three VMs were destroyed and rebuilt with this.

1. Reusable auth key from <https://login.tailscale.com/admin/settings/keys>:

   ```
   printf '%s' 'tskey-auth-...' > ~/.secrets/ts-authkey
   ```

2. Delete the old `nix01` `nix02` `mon01` at
   <https://login.tailscale.com/admin/machines>, or the rebuilt hosts come
   back named `nix01-1` and every hostname breaks.

3. ```
   cd tofu && tofu destroy && tofu apply
   ```

4. Find the new VMs:

   ```
   ssh root@tet01 'ip neigh | grep -i bc:24:11'
   ```

5. Install each one:

   ```
   mkdir -p extra/var/lib/tailscale
   cp ~/.secrets/ts-authkey extra/var/lib/tailscale/authkey

   nix run github:nix-community/nixos-anywhere -- \
     --flake .#nix01 \
     --build-on-remote \
     -i ~/.ssh/chimera_provision \
     --ssh-option ProxyJump=root@tet01 \
     --extra-files extra \
     --target-host root@<ip>
   ```

   It joins Tailscale by itself. Delete `extra/` when done — that file is a
   credential.

## https

| url                                 | what        | managed by      |
|-------------------------------------|-------------|-----------------|
| <https://mon01.merionas.com>        | grafana     | nix, mon01      |
| <https://ingest.merionas.com>       | ingest api  | nix, mon01      |
| <https://tet01.merionas.com:8006>   | proxmox     | pvenode, tet01  |

All real Let's Encrypt certs. For the two on mon01, `nix/modules/tls.nix` has
the plumbing and the vhosts are in the mon01 config. The port on the proxmox
url is not a problem — a certificate covers the name, not the port.

The challenge is DNS-01, not HTTP-01, and that is the whole trick: the host
proves it owns the name by writing a TXT record at Cloudflare, so nothing has
to be reachable from the internet. mon01 still only opens 22 to the LAN, and
Grafana listens on loopback — `http://mon01:3000` is dead on purpose.

Two things live outside the repo:

- Cloudflare API token on mon01 at `/var/lib/secrets/cloudflare.env`,
  `0600 root:root`, scoped `Zone:DNS:Edit` + `Zone:Zone:Read` on merionas.com:

  ```
  printf 'CF_DNS_API_TOKEN=%s\n' "$(pbpaste)" | ssh matt@mon01 \
    'sudo tee /var/lib/secrets/cloudflare.env >/dev/null'
  ```

- A records `mon01.merionas.com` and `ingest.merionas.com`, both ->
  `100.123.4.125`, both **grey cloud**. Orange breaks it twice: Cloudflare
  cannot reach a `100.64/10` address, and it would serve its own cert instead
  of ours.

Ingest still listens on `0.0.0.0:8000` as well, because the phone posts to the
port directly and that would break the moment this deployed. Both paths reach
the same service. Move the shortcut to <https://ingest.merionas.com>, confirm
uploads still land, then close 8000 in `health.nix`.

Renews on a timer. To check:

```
ssh matt@mon01 'systemctl status acme-order-renew-mon01.merionas.com.service'
```

Issuing takes ~2 min because of the propagation wait below — the unit sits in
`activating` the whole time, which is not a hang.

### tet01

tet01 is the proxmox host, not a NixOS VM, so it is not in the flake and none
of the above applies to it. It uses proxmox's own ACME client, configured
imperatively and living in `/etc/pve`. **This is not reproducible from this
repo** — if tet01 is ever reinstalled, redo it:

```
# token, copied from mon01 so it is never retyped
ssh matt@mon01 'sudo sed -n "s/^CF_DNS_API_TOKEN=//p" /var/lib/secrets/cloudflare.env' \
  | ssh root@tet01 'umask 077; sed "s/^/CF_Token=/" > /root/.cf-data'

ssh root@tet01
  pvenode acme plugin add dns cloudflare --api cf --data /root/.cf-data
  rm -f /root/.cf-data
  echo y | pvenode acme account register default matthewmerioles@yahoo.com \
    --directory https://acme-v02.api.letsencrypt.org/directory
  pvenode config set --acme account=default \
    --acmedomain0 tet01.merionas.com,plugin=cloudflare
  pvenode acme cert order
```

Renews itself via `pve-daily-update.timer`.

Two things worth knowing. `pvenode acme plugin list` prints the API token in
full, in plaintext — do not paste its output anywhere. And proxmox stores that
token unencrypted in `/etc/pve/priv/acme/plugins.cfg`, so tet01 holds a
credential that can rewrite all of merionas.com. A second token scoped to just
this zone, separate from mon01's, would limit the blast radius if you ever
want to revoke one without breaking the other.

## gotchas

- `Zone:Zone:Read` on the Cloudflare token is the permission people leave off.
  Without it lego cannot resolve the zone id, and it fails at renewal, not now.
- DNS-01 needs `useACMEHost`, never `enableACME`. `enableACME` makes the nginx
  module set `webroot`, a set webroot silently suppresses the `dnsProvider`
  inherited from `security.acme.defaults`, and lego runs HTTP-01 instead —
  failing with `no valid A records found`, which reads like a DNS problem. Every
  other inherited default still evaluates correctly, so the config looks fine.
  Check it: `nix eval .#nixosConfigurations.mon01.config.security.acme.certs.\"mon01.merionas.com\".dnsProvider`
- lego polls the authoritative nameservers for its TXT record, and Cloudflare
  serves a new record late enough that the poll gives up first — `propagation:
  time limit exceeded ... NXDOMAIN` for a record that resolves a minute later.
  Fixed wait instead of polling: `--dns.propagation-wait`. It is a global lego
  flag, so it goes in `extraLegoFlags`, not `extraLegoRunFlags`.
- VMs must boot `chimera-installer.iso`. The stock NixOS ISO has no SSH key
  baked in, so the only way in is the Proxmox console. nix01 sat uninstalled
  for weeks because of this.
- Multi-disk hosts: address disks by `/dev/disk/by-id/...`, never `/dev/sda`.
  Kernel naming is not stable — mon01 once put the OS on the 256G disk and
  booted the ISO instead.
- After a reinstall: `ssh-keygen -R <host>`.
- `builders` in `/etc/nix/nix.conf` still points at `192.168.1.34`. Should be
  `ssh-ng://nixos@nix01`.

## build the installer iso

```
nix build --max-jobs 0 \
  .#nixosConfigurations.installer.config.system.build.isoImage
```

## replace one vm

```
tofu apply -replace="proxmox_virtual_environment_vm.nix01"
```
