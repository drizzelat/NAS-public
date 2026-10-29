# PLT-1 "How host config deploys": pull, like the script auto-pull. The flake is built
# from the auto-pulled clone at a pinned rev, so a concurrent `reset --hard` cannot race it.
# After a runtime rollback (`nixos-rebuild --rollback`), touch the pause file, or the next
# run re-applies main. docs/runbooks/setup-operations/nixos-cutover.md → Rollback.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  # Off until hosts/nas is on main: before that, main has no flake and every run would fail.
  enabled = false;

  clone = "/mnt/apps/scripts/nas";
  state = "/var/lib/nas-host-deploy";
  hcUrl =
    config.age.secrets.healthchecks-host-deploy-url.path or "/run/agenix/healthchecks-host-deploy-url";

  deploy = pkgs.writeShellScript "nas-host-deploy" ''
    set -euo pipefail
    export PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.curl
        pkgs.gitMinimal
        pkgs.openssh
        config.nix.package
        config.system.build.nixos-rebuild
      ]
    }

    if [ -e ${state}/pause ]; then
      echo "paused (${state}/pause exists) — not deploying"
      exit 0
    fi

    rev=$(git -C ${clone} rev-parse HEAD)
    # SEC-1 step 5 (not enabled yet): git -C ${clone} verify-commit "$rev"

    if [ "$rev" = "$(cat ${state}/rev 2>/dev/null || true)" ] &&
       [ "$(readlink -f /run/current-system)" = "$(cat ${state}/system 2>/dev/null || true)" ]; then
      echo "main $rev already running"
    else
      echo "deploying $rev"
      nixos-rebuild switch --flake "git+file://${clone}?rev=$rev#nas"
      printf '%s\n' "$rev" > ${state}/rev
      readlink -f /run/current-system > ${state}/system
    fi

    if [ -r ${hcUrl} ]; then
      curl -fsS -m 10 --retry 3 "$(cat ${hcUrl})" >/dev/null
    fi
  '';
in
{
  systemd.services.nas-host-deploy = {
    description = "Deploy this host's NixOS config from main";
    after = [
      "network-online.target"
      "nas-pools.target"
    ];
    wants = [ "network-online.target" ];
    requires = [ "nas-pools.target" ];
    onFailure = [ "notify-failure@%n.service" ];
    restartIfChanged = false; # it is the thing doing the switch
    unitConfig.RequiresMountsFor = [ clone ];
    environment.HOME = "/root"; # the clone's deploy key and git config
    serviceConfig = {
      Type = "oneshot";
      ExecStart = deploy;
      StateDirectory = "nas-host-deploy";
    };
  };

  systemd.timers.nas-host-deploy = {
    wantedBy = lib.optional enabled "timers.target";
    timerConfig = {
      OnCalendar = "*-*-* *:40:00"; # after the :37 repo pull
      Persistent = true;
    };
  };
}
