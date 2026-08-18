# Chimera Homelab

Declarative Proxmox homelab using:

- **OpenTofu** — provisions Proxmox VMs
- **NixOS** — configures the operating system
- **Disko** — partitions/formats VM disks
- **nixos-anywhere** — installs NixOS remotely

## Architecture

Mac
│
├── OpenTofu
│   └── Proxmox → creates VMs
│
└── Nix
    ├── Disko → configures disks
    └── NixOS → configures OS/services

## Repository

    .
    ├── tofu/
    │   ├── main.tf
    │   ├── providers.tf
    │   └── .terraform.lock.hcl
    │
    └── nix/
        ├── flake.nix
        ├── flake.lock
        └── hosts/
            └── nix01/
                ├── configuration.nix
                └── disk-config.nix

## 1. Provision VM

Add the VM to `tofu/main.tf`.

Initialize OpenTofu (first time only):

    cd tofu
    tofu init

Preview changes:

    tofu plan

Create/update VMs:

    tofu apply

Destroy OpenTofu-managed infrastructure:

    tofu destroy

## 2. Add NixOS Host

Create:

    nix/hosts/<hostname>/
    ├── configuration.nix
    └── disk-config.nix

Add the host to `nix/flake.nix` under:

    nixosConfigurations.<hostname>

Check available hosts:

    cd nix
    nix flake show

Validate configuration:

    nix flake check

Test a host configuration:

    nix eval .#nixosConfigurations.<hostname>.config.networking.hostName

## 3. Bootstrap VM

Boot the new VM from the NixOS ISO.

From the VM console:

    ip addr
    lsblk
    sudo passwd nixos

Confirm the target disk (normally `/dev/sda`).

Verify SSH from the development machine:

    ssh nixos@<VM_IP>

## 4. Install NixOS

From `nix/`:

    nix run github:nix-community/nixos-anywhere -- \
      --flake .#<hostname> \
      --build-on-remote \
      nixos@<VM_IP>

Disko will partition the target disk and nixos-anywhere will install
the selected NixOS configuration.

**WARNING:** This destroys existing data on the disk configured by Disko.

## 5. Connect

After installation/reboot:

    ssh <user>@<VM_IP>

For Docker hosts:

    docker ps

## Adding Another VM

1. Add VM resource to `tofu/main.tf`
2. Run `tofu plan`
3. Run `tofu apply`
4. Create `nix/hosts/<hostname>/`
5. Add host to `flake.nix`
6. Run `nix flake check`
7. Boot VM from NixOS ISO
8. Get IP and enable temporary SSH access
9. Run `nixos-anywhere`
10. SSH into the finished host