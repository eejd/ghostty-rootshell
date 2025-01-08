{
  system,
  nixpkgs,
  overlay,
  path,
  uid ? 1000,
  gid ? 1000,
}: let
  pkgs = import nixpkgs {
    inherit system;
    overlays = [
      overlay
    ];
  };
in
  nixpkgs.lib.nixosSystem {
    system = builtins.replaceStrings ["darwin"] ["linux"] system;
    modules = [
      {
        virtualisation.vmVariant = {
          virtualisation.host.pkgs = pkgs;
        };

        nixpkgs.overlays = [
          overlay
        ];

        users.groups.ghostty = {
          gid = gid;
        };

        users.users.ghostty = {
          uid = uid;
        };

        system.stateVersion = "24.11";
      }
      ./common.nix
      path
    ];
  }
