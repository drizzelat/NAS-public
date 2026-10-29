# HW-2: NUT for the planned USB HID UPS (docs/roadmap.md → UPS). Shutdown after 5 min on
# battery, deliberately not at "low battery": stopping ~55 containers and exporting the
# pools needs headroom. LOWBATT still shuts down at once (upsmon's own safety net).
{
  config,
  pkgs,
  nasNotify,
  ...
}:
let
  nut = config.power.ups.package;
  onBatterySeconds = 300;
  passwordFile = config.age.secrets.upsmon-password.path or "/run/agenix/upsmon-password";

  # Runs as the unprivileged upsmon user; the two root actions go through sudo rules below.
  cmdScript = pkgs.writeShellScript "upssched-cmd" ''
    notify() { /run/wrappers/bin/sudo -n ${nasNotify}/bin/nas-notify -s "UPS: $1" </dev/null || true; }
    case "$1" in
      onbatt) notify "on battery, shutdown in ${toString onBatterySeconds} s unless power returns" ;;
      online) notify "back on mains" ;;
      lowbatt) notify "low battery" ;;
      commbad) notify "lost contact with the UPS" ;;
      onbatt-shutdown)
        notify "on battery for ${toString onBatterySeconds} s, shutting down"
        /run/wrappers/bin/sudo -n ${nut}/sbin/upsmon -c fsd
        ;;
    esac
  '';

  schedulerRules = pkgs.writeText "upssched.conf" ''
    CMDSCRIPT ${cmdScript}
    PIPEFN /run/upssched/upssched.pipe
    LOCKFN /run/upssched/upssched.lock
    AT ONBATT * START-TIMER onbatt-shutdown ${toString onBatterySeconds}
    AT ONLINE * CANCEL-TIMER onbatt-shutdown
    AT ONBATT * EXECUTE onbatt
    AT ONLINE * EXECUTE online
    AT LOWBATT * EXECUTE lowbatt
    AT COMMBAD * EXECUTE commbad
  '';
in
{
  power.ups = {
    enable = true;
    mode = "standalone";
    ups.main = {
      driver = "usbhid-ups";
      port = "auto";
      description = "USB HID UPS (HW-2)";
    };
    users.upsmon = {
      inherit passwordFile;
      upsmon = "primary";
    };
    upsmon = {
      monitor.main = {
        system = "main@localhost";
        powerValue = 1;
        user = "upsmon";
        inherit passwordFile;
        type = "primary";
      };
      settings.NOTIFYFLAG =
        map
          (e: [
            e
            "SYSLOG+EXEC"
          ])
          [
            "ONLINE"
            "ONBATT"
            "LOWBATT"
            "COMMBAD"
            "COMMOK"
            "SHUTDOWN"
          ];
    };
    schedulerRules = "${schedulerRules}";
  };

  systemd.tmpfiles.rules = [ "d /run/upssched 0750 nutmon nutmon -" ];

  security.sudo.extraRules = [
    {
      users = [ "nutmon" ];
      commands = [
        {
          command = "${nut}/sbin/upsmon -c fsd";
          options = [ "NOPASSWD" ];
        }
        {
          command = "${nasNotify}/bin/nas-notify";
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];

  assertions = [
    {
      assertion = config.power.ups.upsmon.user == "nutmon";
      message = "power.nix sudo rules and /run/upssched assume the upsmon user is nutmon";
    }
  ];
}
