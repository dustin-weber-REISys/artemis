# Failover and manual failback

The initial policy is automatic failover and controlled manual failback.
`allow-failback` remains disabled so a recovered peer cannot create a second
disruption while it is rejoining.

## Planned failover test

Use the verdict-producing performance harness for the active-process and
active-pod cases. It records each successful persistent send in a
force-synchronized external ledger, injects the fault under continuous load,
observes broker `Active` state, and reconciles the ledger after failover.

1. Use a disposable, pre-created durable queue and a client URL with the
   provider's reconnect/failover transport enabled.
2. Run a dry-run plan and inspect its target cluster and selector:

```sh
./performance/run-failure-test.sh \
  --context CONTEXT --cluster CLUSTER --namespace NAMESPACE \
  --profile sustained --fault process-kill
```

3. For an approved test window only, supply `PERF_URL`, `PERF_USERNAME`, and
   `PERF_PASSWORD`, then repeat with `--execute` and exact
   `--confirm-context`, `--confirm-cluster`, and `--confirm-namespace` values.
   Add `--double-failover` to test A active → B active → A active. The harness
   will not inject the second fault until the original broker has restarted
   passive, reports `ReplicaSync=true`, and the replacement active has
   acknowledged another persistent send.
4. Preserve the generated `failure-run.json`, acknowledgement ledger, raw
   send/consume reports, preflight topology, and logs.
5. Treat any missing ledger ID, observed split brain, inconsistent ledger, or
   missed recovery target as a failed test. Ambiguous sends and valid
   redeliveries are evidence to retain, not automatically message loss.

Record the measured recovery time against the current target in
[`tests/e2e/acceptance-plan.yaml`](../../tests/e2e/acceptance-plan.yaml); do
not silently change the target in an execution record.

`gitops/scripts/eks-scenario.sh` remains the action-only runner for the wider
manual matrix. Its reports deliberately remain `NOT_EVALUATED`; do not use
them as message-safety verdicts.

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
