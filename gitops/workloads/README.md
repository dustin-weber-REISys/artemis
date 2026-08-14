# Workload Cell configuration

Each topology entry has one values file at
`<environment>/<workloadCellName>/artemis-values.yaml`. The ApplicationSet
loads it after the reusable Profile and environment integration files, so this
is the typed seam for one HA pair's listeners, Secret references, destinations,
authorization rules, and client NetworkPolicy sources.

Use maps keyed by stable, review-friendly IDs for `acceptors`, `destinations`,
and `authorization.rules`. Helm deep-merges those maps across value layers.
Keep cluster integrations in `environments`, reusable capability defaults in a
Profile, and pair-owned messaging policy here. The chart schema rejects unknown
fields and the topology validator requires exactly one file per catalog entry.

Never store users, passwords, password hashes, private keys, certificate
subjects, certificate contents, token-bearing URLs, or rendered Secrets here.
Use only references to externally materialized SSL and `*-jaas-config` Secrets.
The sanitized, executable configuration example is
[`external-mtls-values.yaml`](../charts/artemis-ha/tests/fixtures/external-mtls-values.yaml).
For legacy Chef environment JSON, generate and review candidates with the
[`Chef ActiveMQ import workflow`](../docs/chef-activemq-import.md); never use a
generated candidate as this file without resolving its disposition report.
