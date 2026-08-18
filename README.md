# Chimera Datacenter

hello this is my datacenter. it is very simple


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

configuring using flake
```
nix run github:nix-community/nixos-anywhere -- \
  --flake .#nix01 \
  --build-on-remote \
  -i ~/.ssh/chimera_provision \
  nixos@<endpoint>
```