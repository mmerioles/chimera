# Chimera Datacenter

hello this is my datacenter. it is very simple


```
nix run github:nix-community/nixos-anywhere -- \
  --flake .#nix01 \
  --build-on-remote \
  -i ~/.ssh/chimera_provision \
  nixos@<endpoint>
```