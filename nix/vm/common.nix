{pkgs, ...}: {
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "ghostty";
  networking.domain = "mitchellh.com";

  virtualisation.vmVariant = {
    virtualisation.memorySize = 2048;
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

  environment.systemPackages = [
    pkgs.kitty
    pkgs.ghostty
  ];

  system.stateVersion = "24.11";
}
