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

## gotchas

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
