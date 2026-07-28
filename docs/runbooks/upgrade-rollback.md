# Upgrade and rollback

Promote the exact tested image and chart digests. Do not upgrade broker,
ZooKeeper, operator, and client libraries as one unobserved change.

## Upgrade

1. Record source versions, immutable digests, SBOM, license inventory, scan
   result, and the operator/operand compatibility matrix.
2. Run the canonical repository validation from the root
   [`README`](../../README.md#validate).
3. Apply the digest to test and run the required compatibility, durability,
   failure, credential rotation, management authorization, and load scenarios
   from [`tests/e2e/acceptance-plan.yaml`](../../tests/e2e/acceptance-plan.yaml).
4. Promote the same digest to nonprod. Run upgrade and rollback there, then
   obtain operational approval before prod.
5. Upgrade one ZooKeeper member at a time, then one Artemis HA pair or
   namespace at a time. Observe replication, queue depth, paging, disk, JVM,
   client reconnect, and Argo health between steps.

## Rollback

1. Stop promotion when Argo, replication, ZooKeeper, client, or message
   accounting evidence is outside its acceptance criteria.
2. Preserve the failed revision, reports, broker logs, Kubernetes events, and
   metrics. Do not purge queues or delete PVCs during triage.
3. Roll back the Argo application to the last approved revision. The generic
   harness remains dry-run until the exact app/revision and confirmations are
   supplied:

```sh
./scripts/eks-scenario.sh --scenario failed-upgrade-rollback \
  --context CONTEXT --cluster CLUSTER --namespace NAMESPACE \
  --argo-app APP --argo-action rollback --argo-revision REVISION
```

4. Execute only during the approved window with exact confirmation flags.
5. Verify the previous broker/operand is synchronized before moving traffic.
   Re-run the client report against the original acknowledged ID range.
6. Record whether the failure was chart/operator, broker, ZooKeeper, storage,
   client compatibility, security, or capacity related.

A rollback restores deployment state; it does not restore deleted data.
Backup/restore is a separate procedure and must not be improvised during an
upgrade incident.
