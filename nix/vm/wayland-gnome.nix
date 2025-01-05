{
  config,
  lib,
  pkgs,
  ...
}: {
  services.displayManager = {
    autoLogin = {
      user = "ghostty";
    };
  };

  services.xserver = {
    enable = true;
    displayManager = {
      gdm = {
        enable = true;
        autoSuspend = false;
      };
    };
    desktopManager = {
      gnome = {
        enable = true;
      };
    };
  };

  environment.etc = {
    "xdg/autostart/com.mitchellh.ghostty.desktop" = {
      source = "${pkgs.ghostty}/share/applications/com.mitchellh.ghostty.desktop";
    };
  };

  environment.systemPackages = [
    pkgs.gnomeExtensions.no-overview
  ];

  environment.gnome.excludePackages = with pkgs; [
    atomix
    cheese
    epiphany
    geary
    gnome-music
    gnome-photos
    gnome-tour
    hitori
    iagno
    tali
  ];

  system.activationScripts = {
    face = {
      text = ''
        mkdir -p /var/lib/AccountsService/{icons,users}

        cp ${pkgs.ghostty}/share/icons/hicolor/1024x1024/apps/com.mitchellh.ghostty.png /var/lib/AccountsService/icons/ghostty

        echo -e "[User]\nIcon=/var/lib/AccountsService/icons/ghostty\n" > /var/lib/AccountsService/users/ghostty

        chown root:root /var/lib/AccountsService/users/ghostty
        chmod 0600 /var/lib/AccountsService/users/ghostty

        chown root:root /var/lib/AccountsService/icons/ghostty
        chmod 0444 /var/lib/AccountsService/icons/ghostty
      '';
    };
  };

  programs.dconf = {
    enable = true;
    profiles.user.databases = [
      {
        settings = with lib.gvariant; {
          "org/gnome/desktop/background" = {
            picture-uri = "file://${pkgs.ghostty}/share/icons/hicolor/512x512/apps/com.mitchellh.ghostty.png";
            picture-uri-dark = "file://${pkgs.ghostty}/share/icons/hicolor/512x512/apps/com.mitchellh.ghostty.png";
            picture-options = "centered";
            primary-color = "#000000000000";
            secondary-color = "#000000000000";
          };
          "org/gnome/desktop/interface" = {
            color-scheme = "prefer-dark";
          };
          "org/gnome/desktop/notifications" = {
            show-in-lock-screen = false;
          };
          "org/gnome/desktop/screensaver" = {
            lock-enabled = false;
            picture-uri = "file://${pkgs.ghostty}/share/icons/hicolor/512x512/apps/com.mitchellh.ghostty.png";
            picture-options = "centered";
            primary-color = "#000000000000";
            secondary-color = "#000000000000";
          };
          "org/gnome/desktop/session" = {
            idle-delay = mkUint32 0;
          };
          "org/gnome/shell" = {
            disable-user-extensions = false;
            enabled-extensions = builtins.map (x: x.extensionUuid) (
              lib.filter (p: p ? extensionUuid) config.environment.systemPackages
            );
          };
        };
      }
    ];
  };

  programs.geary.enable = false;
}
