# Chimera Datacenter

Proxmox host `tet01` with three NixOS VMs and one Debian VM on it.

| host  | what                                | os     |
|-------|-------------------------------------|--------|
| tet01 | proxmox                             | -      |
| mon01 | health dashboard, grafana, influxdb | nixos  |
| nix01 | nix builder                         | nixos  |
| nix02 | docker box                          | nixos  |
| doc01 | docker + grafana                    | debian |

Everything is on Tailscale. Use hostnames, never IPs — the VMs get their
addresses from DHCP and they move.

Flake is at the repo root. Run everything from there. doc01 is not in the
flake — see [doc01](#doc01).

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

   This also rebuilds doc01, and doc01 is finished at this point — cloud-init
   installs everything. The rest of this section is the NixOS hosts only.

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

## doc01

Debian 13, Docker, one Grafana container. Everything is in `tofu/doc01.tf`
and `tofu/doc01-cloud-init.yaml.tftpl`; there is no NixOS config and no
installer ISO for this host.

How it works: tofu downloads the stock Debian cloud image onto tet01 once,
clones it into a disk, and hands the VM a cloud-init file. On first boot
cloud-init creates `matt`, installs Docker from Docker's apt repo, starts
Grafana with `docker compose`, and joins the tailnet. Nothing to do by hand.

### deploy

```
cd tofu
tofu init        # first time only
tofu apply
```

Takes ~5 min: ~400 MB image download, then apt inside the VM. `apply` blocks
until the guest agent reports in, which happens after Docker is installed, so
when it returns Grafana is already up.

Then:

| what     | where                                                 |
|----------|-------------------------------------------------------|
| grafana  | <http://doc01:3000>, user `admin`                     |
| password | `cat ~/.secrets/doc01-grafana-password`               |
| public   | <https://mon.bordgame.app>, same login — see [public url](#public-url) |
| ssh      | `ssh matt@doc01`                                      |
| compose  | `/opt/grafana/docker-compose.yml` on the box          |

Prereqs, all already true on this setup:

- `ssh root@tet01` works with a key in your ssh-agent. The provider uses it
  to copy the cloud-init snippet — the Proxmox API cannot upload snippets.
- `local` storage on tet01 allows `snippets` and `import` content
  (`pvesm set local --content iso,vztmpl,backup,import,snippets`).
- `~/.secrets/doc01-grafana-password` holds the grafana admin password,
  one line, no quotes. Required. Pick anything; it is read at apply time and
  baked into cloud-init, so changing it means a redeploy.
- `~/.secrets/cf-bordgame-token` — see [public url](#public-url). Required.
- `~/.secrets/ts-authkey` exists. Optional — without it the VM still comes
  up, just not on the tailnet, and you reach it by LAN IP from
  `tofu output doc01_ipv4`.

None of these are in the repo. They do end up in `tofu/terraform.tfstate`
(gitignored) and in the cloud-init snippet on tet01 (root only).

### redeploy

cloud-init runs once, so there is no in-place update. Any change to the
template or the values feeding it (Grafana version, SSH keys, password) makes
the next `tofu apply` destroy and recreate the VM — the plan says
`must be replaced`, which is expected. To rebuild without changing anything:

```
tofu apply -replace=proxmox_virtual_environment_vm.doc01
```

Grafana's data lives in a Docker volume on the VM disk, so either wipes it.
Dashboards worth keeping belong in provisioning, not in the UI. Delete the
old `doc01` at <https://login.tailscale.com/admin/machines> first or the new
one comes back as `doc01-1`. Forgot? Delete it now, then on the new box:

```
sudo tailscale set --hostname=doc01-tmp && sleep 3 && sudo tailscale set --hostname=doc01
```

Tailscale only regenerates the machine name when the hostname *changes*, so
it has to be bounced — `tailscale logout` / `up --force-reauth` do not help,
the node keeps its identity and its `-1`. After: `ssh-keygen -R doc01`.

### did it work

```
ssh matt@doc01 'docker ps; sudo tail -20 /var/log/doc01-bootstrap.log'
curl -s http://doc01:3000/api/health
```

Bootstrap log is `/var/log/doc01-bootstrap.log`; cloud-init's own is
`/var/log/cloud-init-output.log`. If `apply` sits for 15 min and fails on the
guest agent, the bootstrap died before installing it — open the proxmox
console (it is wired to the serial port, so the boot log is all there).

### public url

<https://mon.bordgame.app> is grafana on doc01, from anywhere, no tailscale.
It is a Cloudflare Tunnel: a `cloudflared` container next to grafana dials
out to Cloudflare, and Cloudflare routes the hostname back down that
connection. Nothing is port-forwarded and doc01 accepts no inbound
connections from the internet. `tofu/doc01-tunnel.tf` owns the tunnel, its
ingress rule, and the CNAME; the VM only ever sees a tunnel token.

The only thing between the internet and grafana admin is the password in
`~/.secrets/doc01-grafana-password`. If the box ever holds anything
sensitive, put Cloudflare Access in front of it (Zero Trust > Access >
Applications, self-hosted, `mon.bordgame.app`, allow your email).

One-time setup — a Cloudflare API token, scoped to just this zone:

1. <https://dash.cloudflare.com/profile/api-tokens> > Create Token > Custom
   Token, with exactly:

   | scope   | permission         | access |
   |---------|--------------------|--------|
   | Account | Cloudflare Tunnel  | Edit   |
   | Zone    | Zone               | Read   |
   | Zone    | DNS                | Edit   |

   Zone Resources: Include > Specific zone > `bordgame.app`.

2. ```
   printf '%s' 'paste-token-here' > ~/.secrets/cf-bordgame-token
   chmod 600 ~/.secrets/cf-bordgame-token
   ```

3. `cd tofu && tofu apply`. The tunnel token lands in cloud-init, so the
   first apply after adding this rebuilds doc01.

That file is now needed for every `tofu plan`, not just tunnel changes,
because the tunnel resources refresh on every run.

Check it: `curl -sI https://mon.bordgame.app/api/health` should be a 200
with `server: cloudflare`. On the box, `docker logs cloudflared` shows
`Registered tunnel connection` four times when it is healthy. The tunnel also
shows up under Zero Trust > Networks > Tunnels as `doc01`.

The token is a separate one from the merionas.com token on mon01 and tet01,
on purpose — it can be revoked without touching the ACME setup.

Tearing down: `tofu destroy` removes the tunnel and the CNAME but warns that
the tunnel *config* resource "cannot be destroyed from Terraform". That is
the provider being literal — the config is a property of the tunnel and dies
with it, nothing is left behind in the dashboard. `docker logs cloudflared`
also complains about UDP receive buffer size on every start; harmless.

### bord dashboard

Grafana on doc01 reads the bord app's Supabase project directly and shows
players, nights, invites, queue, karma. Nothing runs on doc01 for this beyond
grafana itself — the data stays in Supabase, read through a read-only role
over the session pooler.

```
doc01/grafana/bord-reader.sql          the role + read policies, run once
doc01/grafana/gen_bord_dashboard.py    generates dashboards/bord.json
tofu/doc01-grafana.tf                  pushes datasource + dashboard via API
```

One-time setup:

1. The role. Needs the project's `postgres` password (Supabase dashboard >
   Project Settings > Database; reset it there if you never saved it). Put it
   in `~/.secrets/supabase-bord-postgres`, then from the repo root:

   ```
   ssh matt@doc01 'docker run --rm -i postgres:17-alpine psql \
     "postgresql://postgres.polxedjpnuewjcuxhkzw:'"$(cat ~/.secrets/supabase-bord-postgres)"'@aws-0-ca-central-1.pooler.supabase.com:5432/postgres" \
     -v pw='"'"'"$(cat ~/.secrets/bord-grafana-db-password)"'"'"' -f -' < doc01/grafana/bord-reader.sql
   ```

   The script is idempotent. Re-run it after any bord migration that adds
   tables, or the new tables read as empty in grafana (RLS with no policy).

2. `~/.secrets/bord-grafana-db-password` is the reader's password, generated
   with `openssl rand`. Already there if step 1 ran.

3. `~/.secrets/doc01-grafana-password` — same file as above; tofu logs into
   grafana as admin over the tailnet to push the dashboard.

4. `cd tofu && tofu apply`. Dashboard lands at
   <https://mon.bordgame.app/d/bord> and `tofu output doc01_bord_dashboard`.

Editing: change `gen_bord_dashboard.py`, run it, `tofu apply`. Changes made
in the grafana UI are overwritten on the next apply, so put them in the
generator. The live project has bord migrations 0001-0004 applied; 0005-0008
(regions, referrals + link clicks, standing week, ops outbox, support) are
written but not pushed. The invite section is behind `INVITES = False` in the
generator until 0007 lands — flip it, regenerate, re-run the reader script,
apply.

The `grafana` provider talks to <https://mon.bordgame.app> as admin, so
`tofu plan` now needs doc01 and the tunnel up. On a full fleet rebuild the
first apply creates doc01 and pushes the dashboard in the same run; if
grafana is not up yet when tofu gets there, just apply again.

### upgrades

- **cloudflared:** bump `cloudflared_version` in `doc01-tunnel.tf`, redeploy.
- **Debian image:** bump `debian_build` and `debian_sha512` in `doc01.tf`
  from <https://cloud.debian.org/images/cloud/trixie/> (`SHA512SUMS` in the
  build dir), then redeploy.
- **Grafana:** bump `grafana_version`, redeploy. Or, without redeploy:
  `ssh matt@doc01 'cd /opt/grafana && sudo docker compose pull && sudo docker compose up -d'`
  — but that drifts from the repo until you bump the version there too.
- **OS packages:** `ssh matt@doc01 'sudo apt update && sudo apt upgrade'`.
  Not managed. Or just redeploy — it is a fresh install every time.

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
- After a reinstall: `ssh-keygen -R <host>`. For doc01 also `ssh-keygen -R <ip>` —
  DHCP hands the same address to whatever VM asks next, and an old entry for
  it makes ssh refuse with "REMOTE HOST IDENTIFICATION HAS CHANGED".
- doc01's cloud-init drive must be on `scsi1`, not proxmox's default `ide2`.
  The Debian 13 kernel never probed the IDE CD-ROM on tet01 (no ATAPI line in
  the journal), ds-identify found no `cidata` volume, and cloud-init quietly
  disabled itself — the VM boots to a `localhost login:` prompt with no
  network, no user, nothing in `/var/lib/cloud`. Looks like the image is
  broken; it is not.
- With `ip=dhcp` proxmox still copies tet01's `/etc/resolv.conf` into the
  cloud-init network config, and tet01 resolves through tailscale
  (`100.100.100.100`). A VM not yet on the tailnet cannot reach that, so
  `initialization.dns.servers` is set explicitly for doc01.
- The provider waits up to 15 min for the guest agent on every `plan` and
  `apply` while a VM with `agent.enabled = true` is running without one. If
  doc01 is wedged mid-bootstrap, `ssh root@tet01 qm stop <id>` first, then
  `tofu apply -replace=...`.
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

For the NixOS hosts this leaves an empty VM booting the installer ISO — go to
step 5 of [rebuild the whole fleet](#rebuild-the-whole-fleet). For doc01 it
is the whole job.
