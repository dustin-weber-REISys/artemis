# Upgrade and rollback

Promote the exact tested image and chart digests. Do not upgrade broker,
ZooKeeper, operator, and client libraries as one unobserved change.

## Upgrade

1. Review the centrally selected versions:

   ```sh
   make versions
   ```

2. Run the approved ECR image/chart transfer jobs first. Record their build
   URLs and fingerprinted promotion records; an application upgrade must refer
   to artifacts that already exist in the destination immutable repositories.
3. Preview exactly one operator, broker, or ZooKeeper change. The command is dry-run
   unless `--write` is explicitly supplied:

   ```sh
   ./gitops/scripts/prepare-upgrade.sh \
     --component broker \
     --version VERSION \
     --chart-artifact /path/to/current-operator-chart.tgz
   ```

   The current unmodified operator chart is required for broker upgrades so
   validation can prove that its related-image inventory supports the requested
   broker version. ZooKeeper upgrades require the immutable promoted image digest through
   `--image-digest sha256:...`; changing a tag while retaining the old digest
   does not change the image Kubernetes runs.

   Operator upgrades use the unmodified upstream chart and no longer require a
   vendor rebase. Pull the exact chart and record the OCI, manifest, and image
   provenance, then preview the complete Kustomize change:

   ```sh
   ./gitops/scripts/prepare-upgrade.sh \
     --component operator \
     --version VERSION \
     --chart-artifact /path/to/chart.tgz \
     --chart-oci-digest sha256:... \
     --manifest-sha256 HEX \
     --image-digest sha256:...
   ```

   The command updates the central release, pinned Helm chart version, common
   operator values, and all three private-image overlays in a staged copy. It
   renders every overlay against the supplied chart and fails if the upstream
   Kubernetes objects no longer match the repository-owned transformations.
4. Record source versions, immutable digests, SBOM, license inventory, scan
   result, and the operator/operand compatibility matrix.
5. Run the canonical repository validation from the root
   [`README`](../../README.md#validate).
6. Apply the digest to test and run the required compatibility, durability,
   failure, credential rotation, management authorization, and load scenarios
   from [`tests/e2e/acceptance-plan.yaml`](../../tests/e2e/acceptance-plan.yaml).
7. Promote the same digest to nonprod. Run upgrade and rollback there, then
   obtain operational approval before prod.
8. Upgrade one ZooKeeper member at a time, then one Artemis HA pair or
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
./gitops/scripts/eks-scenario.sh --scenario failed-upgrade-rollback \
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
