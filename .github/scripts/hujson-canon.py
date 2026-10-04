#!/usr/bin/env python3
"""Canonicalise a HuJSON policy file so two copies can be diffed.

Tailscale stores the policy as HuJSON — JSON plus comments and trailing commas. Comments,
key order and whitespace are not drift, so both sides are parsed and re-dumped the same way.
Used by .github/workflows/tailscale-acl.yml; docs: docs/runbooks/setup-operations/tailscale-acl-gitops.md

    hujson-canon.py <file>     # canonical JSON on stdout
"""

import json
import re
import sys


def main():
    if len(sys.argv) != 2:
        print("usage: hujson-canon.py <file>", file=sys.stderr)
        return 2
    src = open(sys.argv[1]).read()
    src = re.sub(r"//[^\n]*", "", src)
    src = re.sub(r"/\*.*?\*/", "", src, flags=re.S)
    # A trailing comma before } or ] is legal HuJSON and a syntax error in JSON.
    src = re.sub(r",(\s*[}\]])", r"\1", src)
    json.dump(json.loads(src), sys.stdout, sort_keys=True, indent=1)
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
