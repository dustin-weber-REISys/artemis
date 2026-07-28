# Failover and manual failback

The initial policy is automatic failover and controlled manual failback.
`allow-failback` remains disabled so a recovered peer cannot create a second
disruption while it is rejoining.

## Planned failover test

1. Record the send report as the acknowledged durable baseline. Start a
   consumer with the same expected sequence range.
2. Run a dry-run plan and inspect the target pod/node before execution:

```sh
./scripts/eks-scenario.sh --scenario active-broker-pod-delete \
  --context CONTEXT --cluster CLUSTER --namespace NAMESPACE \
  --target-pod ACTIVE_BROKER_POD
```

3. For an approved test window only, repeat with `--execute` and exact
   `--confirm-context`, `--confirm-cluster`, and `--confirm-namespace` values.
4. Capture timestamps for broker process loss, passive activation, client
   recovery, replication synchronization, and first successful send/receive.
5. Run the consume report to completion. Missing acknowledged IDs are an RPO
   failure. Duplicate and redelivered IDs are expected observations when a
   consumer or producer was in flight.

The initial liveness target is 30 seconds from failure to recovered client
service. Record the measured value; do not silently change the target.

## Manual failback

1. Do not fail back while the recovered broker is catching up. Verify its PVC,
   journal, replication connection, and synchronized state.
2. Verify ZooKeeper quorum and that only one broker is active.
3. Pause new destructive tests and obtain the change approval.
4. Use the operator-supported manual activation/failback procedure for the
   pinned release. Move one HA pair at a time and watch active/passive state.
5. Re-run a small sequenced send/consume test, then the full expected range.
6. Close the incident/change only after Argo is `Synced`/`Healthy`, both peers
   are in the intended state, and the reports show no missing acknowledged IDs.

Node drain, AZ simulation, one ZooKeeper member loss, quorum loss, and EBS
reschedule are EKS-only tests. The harness is dry-run by default; use the same
exact confirmation flags for every destructive invocation.
