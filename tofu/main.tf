resource "proxmox_virtual_environment_vm" "nix01" {
  name      = "nix01"
  node_name = "tet01"

  bios = "ovmf"

  boot_order = [
    "scsi0",
    "ide3"
  ]

  efi_disk {
    datastore_id = "local-lvm"
  }

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
    interface = "ide3"
    file_id   = "local:iso/chimera-installer.iso"
  }
}

resource "proxmox_virtual_environment_vm" "nix02" {
  name      = "nix02"
  node_name = "tet01"

  bios = "ovmf"

  boot_order = [
    "scsi0",
    "ide3"
  ]

  efi_disk {
    datastore_id = "local-lvm"
  }

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
    interface = "ide3"
    file_id   = "local:iso/chimera-installer.iso"
  }
}

resource "proxmox_virtual_environment_vm" "mon01" {
  name      = "mon01"
  node_name = "tet01"

  bios = "ovmf"

  boot_order = [
    "scsi0",
    "ide3"
  ]

  efi_disk {
    datastore_id = "local-lvm"
  }

  cpu {
    cores = 4
    type  = "host"
  }

  memory {
    dedicated = 8192
  }

  disk {
    datastore_id = "local-lvm"
    interface    = "scsi0"
    size         = 64
  }

  disk {
    datastore_id = "local-lvm"
    interface    = "scsi1"
    size         = 256
  }

  network_device {
    bridge = "vmbr0"
  }

  cdrom {
    interface = "ide3"
    file_id   = "local:iso/chimera-installer.iso"
  }
}