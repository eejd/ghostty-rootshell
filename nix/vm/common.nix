{pkgs, ...}: {
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  documentation.nixos.enable = false;

  networking.hostName = "ghostty";
  networking.domain = "mitchellh.com";

  virtualisation.vmVariant = {
    virtualisation.memorySize = 2048;
  };

  nix = {
    settings = {
      trusted-users = [
        "root"
        "ghostty"
      ];
    };
    extraOptions = ''
      experimental-features = nix-command flakes
    '';
  };

  users.mutableUsers = true;

  users.groups.ghostty = {
    gid = 1000;
  };

  users.users.ghostty = {
    description = "Ghostty";
    uid = 1000;
    group = "ghostty";
    extraGroups = ["wheel"];
    isNormalUser = true;
    initialPassword = "ghostty";
  };

  environment.etc = {
    "xdg/autostart/com.mitchellh.ghostty.desktop" = {
      source = "${pkgs.ghostty}/share/applications/com.mitchellh.ghostty.desktop";
    };
  };

  environment.systemPackages = [
    pkgs.kitty
    pkgs.ghostty
    pkgs.helix
    pkgs.neovim
    pkgs.zig_0_13
  ];

  security.polkit = {
    enable = true;
  };

  services.dbus = {
    enable = true;
  };

  services.displayManager = {
    autoLogin = {
      user = "ghostty";
    };
  };

  services.libinput = {
    enable = true;
  };

  services.qemuGuest = {
    enable = true;
  };

  services.spice-vdagentd = {
    enable = true;
  };

  services.xserver = {
    enable = true;
  };

  system.stateVersion = "24.11";
}
