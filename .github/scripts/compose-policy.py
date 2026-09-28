#!/usr/bin/env python3
"""Enforce the compose conventions every stack already follows by habit.

Per service, in every `stacks/*/docker-compose.yml`:

  * the image is pinned `tag@sha256:<digest>`, and the tag is not `latest`
    (Renovate and the review gate need a version string to read release notes),
  * `restart:` is set,
  * `privileged: true` never appears,
  * `/var/run/docker.sock` is mounted only by the services in SOCKET_ALLOWED,
  * `security_opt` carries `no-new-privileges`, unless NNP_EXEMPT names a reason,
  * a memory limit is set, unless LIMIT_EXEMPT names a reason,
  * `logging:` caps the log size on every service: Docker's default json-file log grows
    without bound (a NAS socket proxy reached 1.6 GB in one file).

An exemption that no longer matches anything (service gone, or now compliant) is a
finding too, so the lists cannot rot. Runs in the `validate` job of compose-validate.yml;
by hand: `python3 .github/scripts/compose-policy.py`. Docs: docs/runbooks/setup-operations/new-service.md

Exit 0 = clean, 1 = findings (GitHub error annotations), 2 = the script could not run.
"""

import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
STACKS = ROOT / "stacks"

# (stack, service) -> why the docker socket is needed. "*" matches any stack.
SOCKET_ALLOWED = {
    ("nas-periphery", "periphery"): "Komodo deploys through it",
    ("a1-vps-periphery", "periphery"): "Komodo deploys through it",
    ("micro-vps-periphery", "periphery"): "Komodo deploys through it",
    ("runner-vm-periphery", "periphery"): "Komodo deploys through it",
    ("*", "beszel-socket-proxy"): "GET-only proxy in front of the socket for the Beszel agent",
    ("caddy", "crowdsec-socket-proxy"): "GET-only proxy in front of the socket, so CrowdSec can "
                                        "read Authentik's stdout without one of its own",
}

# (stack, service) -> reason. Every service either complies or is named here with one.
NNP_EXEMPT = {
    ("tailscale", "tailscale"): "tailscaled rewrites iptables/routing (docs/services/tailscale.md)",
}

LIMIT_EXEMPT = {}

findings = []


def finding(stack, msg):
    findings.append((f"stacks/{stack}/docker-compose.yml", msg))


def lookup(table, stack, svc):
    return (stack, svc) in table or ("*", svc) in table


def load_compose(path):
    """Parse a compose file; without PyYAML, let `docker compose config` do it (as docs-drift.py does)."""
    try:
        import yaml  # noqa: PLC0415 — optional dependency, probed on purpose
    except ImportError:
        out = subprocess.run(["docker", "compose", "-f", str(path), "config", "--format", "json"],
                             capture_output=True, text=True, check=False)
        if out.returncode != 0:
            print(f"cannot parse {path}: no PyYAML and docker compose failed", file=sys.stderr)
            sys.exit(2)
        return json.loads(out.stdout)
    with path.open() as fh:
        return yaml.safe_load(fh)


def has_nnp(svc):
    return any(re.sub(r"[\s:=]+", "=", str(o)).startswith("no-new-privileges")
               and not str(o).endswith("false")
               for o in svc.get("security_opt") or [])


def has_mem_limit(svc):
    limits = ((svc.get("deploy") or {}).get("resources") or {}).get("limits") or {}
    return bool(limits.get("memory") or svc.get("mem_limit"))


def has_log_cap(svc):
    logging = svc.get("logging") or {}
    driver = logging.get("driver", "json-file")
    # `local` rotates by default (100 MB total); json-file needs an explicit max-size.
    return driver in ("local", "none", "journald") or bool((logging.get("options") or {}).get("max-size"))


def mounts_socket(svc):
    for v in svc.get("volumes") or []:
        src = v.get("source", "") if isinstance(v, dict) else str(v).split(":")[0]
        if src.rstrip("/").endswith("docker.sock"):
            return True
    return False


def main():
    if not STACKS.is_dir():
        print("no stacks/ directory — wrong working directory?", file=sys.stderr)
        return 2
    seen = set()

    for compose_path in sorted(STACKS.glob("*/docker-compose.yml")):
        stack = compose_path.parent.name
        compose = load_compose(compose_path)
        if not isinstance(compose, dict):
            finding(stack, "does not parse to a mapping")
            continue
        for name, svc in (compose.get("services") or {}).items():
            key = (stack, name)
            seen.add(key)
            image = str(svc.get("image") or "")

            if image:
                if "@sha256:" not in image:
                    finding(stack, f"{name}: image {image} is not pinned by digest (tag@sha256:...)")
                ref = image.split("@")[0]
                tag = ref.rsplit(":", 1)[1] if ":" in ref.rsplit("/", 1)[-1] else ""
                if tag in ("", "latest"):
                    finding(stack, f"{name}: image {ref} has no version tag — pin a release, not latest")
            elif not svc.get("build"):
                finding(stack, f"{name}: no image and no build")

            if not svc.get("restart"):
                finding(stack, f"{name}: no restart policy")
            if svc.get("privileged"):
                finding(stack, f"{name}: privileged: true is not allowed")
            if mounts_socket(svc) and not lookup(SOCKET_ALLOWED, stack, name):
                finding(stack, f"{name}: mounts the docker socket; front it with a socket proxy, "
                               "or add it to SOCKET_ALLOWED with a reason")

            if has_nnp(svc):
                if key in NNP_EXEMPT:
                    finding(stack, f"{name}: now sets no-new-privileges, drop it from NNP_EXEMPT")
            elif key not in NNP_EXEMPT:
                finding(stack, f"{name}: add security_opt: [no-new-privileges=true], "
                               "or a reason to NNP_EXEMPT in .github/scripts/compose-policy.py")

            if has_mem_limit(svc):
                if key in LIMIT_EXEMPT:
                    finding(stack, f"{name}: now has a memory limit, drop it from LIMIT_EXEMPT")
            elif key not in LIMIT_EXEMPT:
                finding(stack, f"{name}: add deploy.resources.limits.memory, "
                               "or a reason to LIMIT_EXEMPT in .github/scripts/compose-policy.py")

            if not has_log_cap(svc):
                finding(stack, f"{name}: set logging: with a max-size "
                               "(the x-logging anchor every other stack uses)")

    for table, label in ((NNP_EXEMPT, "NNP_EXEMPT"), (LIMIT_EXEMPT, "LIMIT_EXEMPT"),
                         (SOCKET_ALLOWED, "SOCKET_ALLOWED")):
        for stack, name in table:
            if stack != "*" and (stack, name) not in seen:
                findings.append((".github/scripts/compose-policy.py",
                                 f"{label} names {stack}/{name}, which no longer exists"))

    for path, msg in findings:
        print(f"::error file={path}::{msg}")
    print(f"\ncompose policy: {len(findings)} finding(s)")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
