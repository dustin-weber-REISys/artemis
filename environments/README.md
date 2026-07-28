# Environment composition

The `test`, `nonprod`, and `prod` ZooKeeper overlays deliberately keep the
three-member quorum, persistent gp3-compatible volumes, zone spread, network
policies, and observability resources in parity. They vary capacity and
environment placeholders only. The same ZooKeeper image digest is shown in
each overlay to make immutable promotion explicit.

The `sandbox` overlay is the sole exception. It sets `enabled: false`,
`haMode: none`, and `replicaCount: 1` as an environment composition. It is for
rendering and developer iteration only and is not a promotion profile.

Before use, replace the `PLACEHOLDER_*` values through the environment or Argo
CD deployment configuration. Do not commit credentials, account IDs, real
cluster names, domains, or secret contents.
