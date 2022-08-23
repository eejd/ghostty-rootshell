final: prev: rec {
  # Notes:
  #
  # When determining a SHA256, use this to set a fake one until we know
  # the real value:
  #
  #    vendorSha256 = nixpkgs.lib.fakeSha256;
  #

  devShell = prev.callPackage ./devshell.nix { };
  ghostty = prev.callPackage ./package.nix { };

  wraptest = prev.callPackage ./wraptest.nix { };

  # zig we want to be the latest nightly since 0.9.0 is not released yet.
  # NOTE: we are pinned to this master version because it broke at a certain
  # point due to the self-hosted compiler. We'll fix this ASAP.
  zig = final.zigpkgs.master-2022-08-19;
}
