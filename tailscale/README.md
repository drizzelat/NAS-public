# Tailnet policy

`policy.hujson` is the tailnet's access-control policy. A PR touching it runs the policy's own
tests; merging to `main` **applies** it, replacing whatever is live.

The file is not here yet — seed it from the live policy first, never write it from scratch:
[tailscale-acl-gitops.md](../docs/runbooks/setup-operations/tailscale-acl-gitops.md).
