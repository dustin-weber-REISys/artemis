# Incident triage

The first objective is to protect safety: one active broker and no loss of
broker-acknowledged durable messages. At-least-once delivery permits duplicate
or redelivered in-flight messages.

## First five minutes

1. Record UTC time, approved context/cluster/namespace, current Argo revision,
   active/passive broker identities, ZooKeeper quorum, replication state, and
   client recovery duration. Do not record credentials or message bodies.
2. Check Argo `Synced`/`Healthy`, pod events, PVC attachment, node/zone
   placement, PDB status, broker active/passive state, replication connected /
   synchronized state, and ZooKeeper sessions/quorum.
3. Check queue depth, delivering/unacknowledged count, blocked producers,
   paging/disk, JVM heap/GC, file descriptors, and reconnect errors.
4. Freeze upgrades, rollouts, purge/move operations, and automatic failback.
   Do not delete PVCs or force a second broker active.
5. Preserve structured logs, Kubernetes events, metrics, Argo history, and the
   latest validation reports.

## Decision paths

- **Two active brokers or coordination uncertainty:** isolate client traffic
  using the approved network controls, page the platform owner, and do not
  promote either side until ZooKeeper and journal ownership are proven.
- **ZooKeeper quorum loss:** expect no new activation; restore quorum one
  member at a time and verify exactly one active broker.
- **Replication disconnected:** keep the surviving active broker under the
  approved write policy, measure the acknowledged-send boundary, and do not
  fail back until synchronization is complete.
- **PVC/EBS issue:** preserve the volume and instance identity, inspect attach
  events, and use the backup/restore runbook if the volume cannot be recovered.
- **Credential, TLS, Keycloak, or Vault issue:** stop rotation/restarts, verify
  file-rendered secret paths and certificate validity without printing values,
  then restart one HA peer at a time.

Use `scripts/eks-scenario.sh` for scoped evidence. It is dry-run by default;
destructive execution requires the exact context, cluster, and namespace
confirmation flags. The script cannot replace an incident commander or an
approved EKS change window.

## Exit criteria

Argo is healthy, exactly one broker is active, ZooKeeper has the intended
quorum, replication is synchronized, client service meets the measured target,
and the validation report has no missing acknowledged IDs. Attach a timeline,
root cause, impact, redelivery/duplicate accounting, recovery evidence, and
follow-up actions.
