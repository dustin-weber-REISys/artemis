# Failover and controlled role reversal

The competing-primary pair fails over automatically. The chart exposes no
separate automatic-failback switch: a recovered peer must rejoin passive, and
operators may reverse roles only after synchronization and change approval.

## Internal Service endpoint acceptance

INT SKY's optional `broker` Service is an `ExternalName` alias to
`test-sky-artemis-artemis-ha-artemis.artemis-int-sky.svc.cluster.local`.
It shortens DNS only. Both healthy peers pass the current readiness probe, so
the target ClusterIP Service can route a connection attempt to either peer.
The passive broker is not a usable messaging endpoint; ActiveMQ Classic
Java/JMS clients must retain the failover transport:

```text
failover:(tcp://broker.artemis-int-sky.svc.cluster.local:61616)?maxReconnectAttempts=-1&startupMaxReconnectAttempts=-1
```

This is a retry-based connection contract, not active-only routing. Unlimited
retries do not guarantee a maximum recovery time. Application transaction
rollback/redelivery handling and measured timeout behavior remain part of
acceptance. Other client libraries require their own reconnect syntax.
See the [documentation and source assessment](../internal-broker-failover-research.md).

On the authorized work computer, collect the deployed Service configuration
and endpoint membership with these read-only commands. This offline checkout
must not run them against a cluster:

```sh
export ARTEMIS_CONTEXT='REPLACE_WITH_APPROVED_TEST_CONTEXT'
kubectl --context "$ARTEMIS_CONTEXT" -n artemis-int-sky \
  get service broker test-sky-artemis-artemis-ha-artemis -o yaml
kubectl --context "$ARTEMIS_CONTEXT" -n artemis-int-sky \
  get endpointslices \
  -l kubernetes.io/service-name=test-sky-artemis-artemis-ha-artemis -o yaml
kubectl --context "$ARTEMIS_CONTEXT" -n artemis-int-sky \
  get pods -l ActiveMQArtemis=test-sky-artemis-artemis-ha -o wide
```

The alias should name the target above, with port `61616`. The target must
use `ClusterIP`, `internalTrafficPolicy: Cluster`, and no `ClientIP` session
affinity. Kubernetes defaults omitted `sessionAffinity` to `None`. Affinity
can repeatedly send a retrying client to the same passive endpoint. Record
any cluster-specific traffic-distribution behavior as part of the evidence.
Readiness and EndpointSlices alone do not establish broker role or replica
synchronization.

Before developer handoff, run `internal-service-endpoint-failover` from the
[acceptance plan](../../tests/e2e/acceptance-plan.yaml) using a client inside
the cluster with the actual application NetworkPolicy identity. Test fresh
connections with each peer active, then an existing connection across both
directions of an approved failover, checking durable-message acknowledgements
and recovery time. Do not execute disruptive steps outside an approved test
window. The existing harness below supplies ledger and fault-test procedures,
but a laptop Docker client cannot normally resolve cluster-local DNS; arrange
an authorized client execution environment that really traverses the Service.
Neither a pod tunnel nor `kubectl port-forward service/...` validates
ClusterIP endpoint selection. Keep this case NOT_RUN until that evidence
exists; local render tests cannot certify live failover.

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

## Controlled role reversal

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
