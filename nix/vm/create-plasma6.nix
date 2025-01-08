{
  system,
  nixpkgs,
  overlay,
  path,
  uid ? 1000,
  gid ? 1000,
}:
import ./create.nix {
  inherit system nixpkgs overlay path uid gid;
  common = ./common-plasma6.nix;
}
