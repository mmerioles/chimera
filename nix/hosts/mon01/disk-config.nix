{
  disko.devices = {
    disk = {
      os = {
        type = "disk";
        device = "/dev/sda";

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
        device = "/dev/sdb";

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
  };
}