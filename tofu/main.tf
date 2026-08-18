resource "proxmox_virtual_environment_vm" "nix01" {
  name      = "nix01"
  node_name = "tet01"

  cpu {
    cores = 4
  }

  memory {
    dedicated = 8192
  }

  disk {
    datastore_id = "local-lvm"
    interface    = "scsi0"
    size         = 64
  }

  network_device {
    bridge = "vmbr0"
  }

  cdrom {
    file_id = "local:iso/nixos-minimal-26.05.7813.0dd31db7e6db-x86_64-linux.iso"
  }
}