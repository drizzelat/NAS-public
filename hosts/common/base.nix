{ ... }:
{
  i18n.defaultLocale = "en_US.UTF-8";

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  # TrueNAS shipped SystemMaxUse=50M: a file capped at ~6 MB and a rotation every ~13 min.
  # The journal stays on the boot disk (never on ZFS: journald-zil-deadlock).
  services.journald.extraConfig = ''
    SystemMaxUse=2G
    SystemMaxFileSize=128M
    MaxRetentionSec=1month
  '';

  users.mutableUsers = false;
  security.sudo.wheelNeedsPassword = false; # the admin user has passwordless sudo on every host
}
