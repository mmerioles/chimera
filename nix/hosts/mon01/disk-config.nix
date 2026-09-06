# Addressed by stable id, never /dev/sdX. With two virtio-scsi disks the
# kernel does not guarantee which one becomes sda: an install once put the OS
# on the 256G disk and the influx filesystem on the 64G boot disk, so the VM
# booted scsi0, found no ESP, and fell through to the installer ISO. These
# by-id names map straight to the Proxmox slot and cannot be reordered.

{
  disko.devices.disk = {
    os = {
      type = "disk";
      device = "/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi0";

      content = {
        type = "gpt";

        partitions = {
          ESP = {
            size = "512M";
            type = "EF00";

            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
            };
          };

          root = {
            size = "100%";

            content = {
              type = "filesystem";
              format = "ext4";
              mountpoint = "/";
            };
          };
        };
      };
    };

    influx = {
      type = "disk";
      device = "/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi1";

      content = {
        type = "gpt";

        partitions = {
          data = {
            size = "100%";

            content = {
              type = "filesystem";
              format = "ext4";
              mountpoint = "/var/lib/influxdb3";
            };
          };
        };
      };
    };
  };
}