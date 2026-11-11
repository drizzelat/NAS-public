# Pull-deploy of main, as on the NAS (hosts/nas/deploy.nix), from the A1's own clone: Komodo's clone
# moves only when an A1 stack deploys. After a runtime rollback, touch the pause file (a1-nixos-cutover.md).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  state = "/var/lib/a1-host-deploy";
  clone = "${state}/nas"; # jobs.nix runs the host scripts from here too
  key = config.age.secrets.a1-deploy-key.path or "/run/agenix/a1-deploy-key";

  deploy = pkgs.writeShellScript "a1-host-deploy" ''
    set -euo pipefail
    export PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.gitMinimal
        pkgs.openssh
        config.nix.package
        config.system.build.nixos-rebuild
        config.systemd.package # nixos-rebuild switches via systemd-run
      ]
    }
    export GIT_SSH_COMMAND="ssh -i ${key} -o IdentitiesOnly=yes -o BatchMode=yes"

    if [ -e ${state}/pause ]; then
      echo "paused (${state}/pause exists) — not pulling or deploying"
      exit 0
    fi

    [ -d ${clone}/.git ] || git clone --quiet --branch main git@github.com:drizzelat/NAS.git ${clone}
    git -C ${clone} fetch --quiet origin main
    git -C ${clone} reset --quiet --hard origin/main
    rev=$(git -C ${clone} rev-parse HEAD)

    if [ "$rev" = "$(cat ${state}/rev 2>/dev/null || true)" ] &&
       [ "$(readlink -f /run/current-system)" = "$(cat ${state}/system 2>/dev/null || true)" ]; then
      echo "main $rev already running"
      exit 0
    fi
    echo "deploying $rev"
    # Built from the pinned rev, so a later reset of the working tree cannot race the build.
    nixos-rebuild switch --flake "git+file://${clone}?rev=$rev#a1"
    printf '%s\n' "$rev" > ${state}/rev
    readlink -f /run/current-system > ${state}/system
  '';
in
{
  # GitHub's published key (api.github.com/meta), so the first clone needs no trust-on-first-use.
  programs.ssh.knownHosts."github.com".publicKey =
    "ssh-ed25519 <redacted>";

  systemd.services.a1-host-deploy = {
    description = "Pull main and deploy this host's NixOS config";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    onFailure = [ "notify-failure@%n.service" ];
    restartIfChanged = false; # it is the thing doing the switch
    environment.HOME = "/root";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = deploy;
      StateDirectory = "a1-host-deploy";
    };
  };

  systemd.timers.a1-host-deploy = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "5min"; # first boot after install: clone soon, so the jobs have their scripts
      OnCalendar = "*-*-* *:45:00";
      Persistent = true;
    };
  };
}
