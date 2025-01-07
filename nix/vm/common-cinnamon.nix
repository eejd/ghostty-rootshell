{...}: {
  services.xserver = {
    displayManager = {
      lightdm = {
        enable = true;
      };
    };
    desktopManager = {
      cinnamon = {
        enable = true;
      };
    };
  };
}
