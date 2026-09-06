# Chimera Datacenter

hello this is my datacenter. it is very simple

The flake lives at the repo root (not in `nix/`) so it can reach the app
sources in `health/` - Nix only copies files under the flake into the store.
Run everything below from the repo root.

Every host is on the tailnet, so they answer to their own name - `tet01`,
`nix01`, `nix02`, `mon01` - from anywhere. The VMs still run DHCP and their
LAN addresses do move, but nothing needs to know that any more.

replacing specific host
```
tofu apply -replace="proxmox_virtual_environment_vm.nix01"
```

build iso remotely
```
nix build \
  --max-jobs 0 \
  .#nixosConfigurations.installer.config.system.build.isoImage
```

rebuild a vm
```
nix run nixpkgs#nixos-rebuild -- switch \
  --flake .#mon01 \
  --target-host matt@mon01 \
  --build-host matt@mon01 \
  --sudo
```

Deploy as `matt --sudo`, never `root`: the hosts set `PermitRootLogin = "no"`
and give root no authorized keys, so a `root@` target is refused.
`wheelNeedsPassword = false` keeps `--sudo` non-interactive.

`--build-host` points at the target because this repo is usually driven from an
arm64 Mac while the hosts are x86_64-linux.

rebuilding the whole fleet from nothing

This path is tested - all three VMs were destroyed and rebuilt with it.

**1.** Put a *reusable* auth key from
<https://login.tailscale.com/admin/settings/keys> in `~/.secrets/ts-authkey`,
with no trailing newline:

```
printf '%s' 'tskey-auth-...' > ~/.secrets/ts-authkey && chmod 600 ~/.secrets/ts-authkey
```

**2.** Delete the old `nix01`/`nix02`/`mon01` entries at
<https://login.tailscale.com/admin/machines>. A rebuilt host that asks for a
name another node still holds silently becomes `nix01-1`, which breaks every
`matt@nix01` deploy while looking like the rebuild failed.

**3.** Recreate the VMs:

```
cd tofu && tofu destroy && tofu apply
```

**4.** Fresh VMs are not on the tailnet yet, so find each one by MAC from
tet01 and install it:

```
ssh root@tet01 'ip neigh | grep -i bc:24:11'

mkdir -p extra/var/lib/tailscale
cp ~/.secrets/ts-authkey extra/var/lib/tailscale/authkey

nix run github:nix-community/nixos-anywhere -- \
  --flake .#nix01 \
  --build-on-remote \
  -i ~/.ssh/chimera_provision \
  --ssh-option ProxyJump=root@tet01 \
  --extra-files extra \
  --target-host root@<lan-address>
```

`--extra-files` plants the auth key inside the target during install, so the
host joins the tailnet on first boot with nothing typed by hand and answers to
its own name from then on. `extra/` is gitignored - the key is a credential
and must never be committed. Delete it when you are done.

The VM must boot `chimera-installer.iso`; only that image has
`chimera_provision.pub` baked in as root's key (`nix/installer/configuration.nix`).
All three already reference it in `tofu/main.tf`. With the stock
`nixos-minimal` ISO there is no way in but the Proxmox console - nix01 sat
uninstalled for weeks for exactly that reason.

Two things that cost real time the first time through:

- **Never address a multi-disk host as `/dev/sda`.** Kernel naming is not
  stable: mon01's install put the OS on the 256G disk and the influx
  filesystem on the 64G boot disk, so it booted scsi0, found no ESP, and fell
  back to the ISO looking like a failed install. `mon01/disk-config.nix` now
  uses `/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi0`, which maps to
  the Proxmox slot and cannot be reordered.
- Reinstalled hosts get new SSH host keys. `ssh-keygen -R <host>` before
  connecting.

Note `builders` in `/etc/nix/nix.conf` on the Mac still points at
`ssh-ng://nixos@192.168.1.34`, which is stale and breaks whenever DHCP moves
things. It should be `ssh-ng://nixos@nix01`.
