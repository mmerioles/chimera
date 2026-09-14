# ------------------------------------------------------------
# doc01: Debian 13 + Docker + Grafana.
#
# Unlike the NixOS hosts, this one is not installed from the chimera ISO. It
# boots the stock Debian cloud image and cloud-init does the rest on first
# boot: create the user, install Docker, start Grafana. Nothing to run by hand
# after `tofu apply`.
#
# cloud-init only runs once, on first boot. To pick up a change to anything in
# this file, replace the VM:
#
#   tofu apply -replace=proxmox_virtual_environment_vm.doc01
# ------------------------------------------------------------

locals {
  doc01 = {
    # Pinned build so the same apply produces the same VM. New builds appear at
    # https://cloud.debian.org/images/cloud/trixie/ - bump both lines together.
    debian_build  = "20260831-2587"
    debian_sha512 = "5a069019420fb9441ad4f8004c661fadb747edd5662ca54a17c8f923dee7d717e21dbdaa4ba72d6fce7f920e0217f0a9af382298a7d46ed4bc9dc33ac19181b6"

    grafana_version = "13.2.1"

    # Public on the internet via the tunnel, so a real one, and not in the
    # repo. Edit the file and redeploy; grafana only reads it on first start.
    grafana_password = trimspace(file(pathexpand("~/.secrets/doc01-grafana-password")))

    ssh_keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIP193fLq/J/V8/vBpEqQCSqW+UUbfC+sflm9OEpno9Hm matthewmerioles@yahoo.com",
      trimspace(file("${path.module}/../nix/keys/chimera_provision.pub")),
    ]

    # Same reusable key the NixOS hosts use (see README "rebuild the whole
    # fleet"). Optional: without the file the VM still comes up, just not on
    # the tailnet.
    tailscale_authkey = fileexists(pathexpand("~/.secrets/ts-authkey")) ? trimspace(file(pathexpand("~/.secrets/ts-authkey"))) : ""
  }
}

resource "proxmox_virtual_environment_download_file" "debian_13" {
  node_name    = "tet01"
  datastore_id = "local"
  content_type = "import"

  url                = "https://cloud.debian.org/images/cloud/trixie/${local.doc01.debian_build}/debian-13-generic-amd64-${local.doc01.debian_build}.qcow2"
  file_name          = "debian-13-generic-amd64-${local.doc01.debian_build}.qcow2"
  checksum           = local.doc01.debian_sha512
  checksum_algorithm = "sha512"
}

resource "proxmox_virtual_environment_file" "doc01_cloud_init" {
  node_name    = "tet01"
  datastore_id = "local"
  content_type = "snippets"

  # Lands 0644 in /var/lib/vz/snippets on tet01 with the grafana password and
  # tailscale key in it. file_mode would fix that but is root@pam only, and we
  # authenticate with a token. Only root has a shell on tet01, so this is the
  # same exposure as the ACME token there (README, "tet01").

  source_raw {
    file_name = "doc01.cloud-config.yaml"
    data = templatefile("${path.module}/doc01-cloud-init.yaml.tftpl", {
      hostname          = "doc01"
      ssh_keys          = local.doc01.ssh_keys
      grafana_version   = local.doc01.grafana_version
      grafana_password  = local.doc01.grafana_password
      tailscale_authkey = local.doc01.tailscale_authkey
      public_url        = "https://${local.tunnel.hostname}"
      tunnel_token      = data.cloudflare_zero_trust_tunnel_cloudflared_token.doc01.token
      cloudflared_ver   = local.tunnel.cloudflared_version
    })
  }
}

resource "proxmox_virtual_environment_vm" "doc01" {
  name      = "doc01"
  node_name = "tet01"
  tags      = ["debian", "docker"]

  bios = "ovmf"

  efi_disk {
    datastore_id = "local-lvm"
    type         = "4m"
  }

  cpu {
    cores = 2
    type  = "host"
  }

  memory {
    dedicated = 4096
  }

  disk {
    datastore_id = "local-lvm"
    interface    = "scsi0"
    import_from  = proxmox_virtual_environment_download_file.debian_13.id
    size         = 32
    discard      = "on"
  }

  network_device {
    bridge = "vmbr0"
  }

  operating_system {
    type = "l26"
  }

  # Cloud images log to the serial port; this makes the proxmox console show it.
  serial_device {}
  vga {
    type = "serial0"
  }

  # cloud-init installs and starts qemu-guest-agent, which is what lets the
  # provider report the IP below and shut the VM down cleanly.
  agent {
    enabled = true
  }

  initialization {
    datastore_id      = "local-lvm"
    user_data_file_id = proxmox_virtual_environment_file.doc01_cloud_init.id

    # On the virtio-scsi bus, not the default ide2. The Debian 13 kernel never
    # saw the IDE CD-ROM on this host (no ATAPI probe in the journal), so
    # ds-identify found no cidata volume and cloud-init disabled itself.
    interface = "scsi1"

    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }

    # Without this proxmox copies tet01's resolv.conf into the VM, and tet01
    # resolves through tailscale (100.100.100.100), which a VM that is not on
    # the tailnet yet cannot reach.
    dns {
      servers = ["1.1.1.1", "9.9.9.9"]
    }
  }

  # Cloud-init state, disk and grafana volume all die with the VM; nothing on
  # it is worth a graceful shutdown wait when replacing it.
  stop_on_destroy = true
}

output "doc01_ipv4" {
  description = "LAN address doc01 got from DHCP. Prefer the hostname over the tailnet."
  # eth0 only - the agent also reports docker bridges and tailscale0.
  value = flatten([
    for i, name in proxmox_virtual_environment_vm.doc01.network_interface_names :
    proxmox_virtual_environment_vm.doc01.ipv4_addresses[i] if name == "eth0"
  ])
}

output "doc01_grafana_admin_password" {
  value     = local.doc01.grafana_password
  sensitive = true
}
