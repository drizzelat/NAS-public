# Key-only sshd. Each host sets its port and its users' keys.
{ ... }:
{
  services.openssh = {
    enable = true;
    # Keys come only from Nix; ~/.ssh/authorized_keys is ignored.
    authorizedKeysInHomedir = false;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
      AllowTcpForwarding = false;
      X11Forwarding = false;
    };
  };
}
