# Upgrade and rollback

Promote the exact tested image tags and chart artifact. Treat Kubernetes, operator,
broker, ZooKeeper, and client-library changes as separate observed Platform
Release changes. Publish a new immutable image tag for every application or
base-OS rebuild; do not reuse a deployed tag.

> This repository is an offline/test copy. Run registry, Kubernetes, and Argo CD
> steps below only from the authorized work computer and approved
> contexts. The repository commands are local, deterministic, and do not deploy.

## Upgrade

### 1. Select one change

Review the centrally selected Platform Release:

```sh
make versions
```

Use one pull request and change window per row:

| Component | Required preview inputs | Repository-owned result |
| --- | --- | --- |
| Kubernetes | semantic version | central platform assumption used by schema validation |
| Operator | version, chart artifact/provenance, and optional image-tag override | central version/provenance, image tag, and every operator overlay |
| Broker | version, current operator chart, and optional init/runtime image-tag overrides | central version, image tags, chart schema/default, and related-image mappings |
| ZooKeeper | version and optional image-tag override | central version, image tag, pod labels, and image references |

Do not combine control-plane, operator, operand, or client changes
just because they are mutually compatible. Separate changes preserve a useful
rollback boundary.

### 2. Record artifact and live baselines

Run the approved ECR image/chart transfer jobs first. Record their build URLs
and promotion records; the tagged artifacts must already exist in destination
repositories with ECR tag immutability enabled. Record the operator, Artemis
broker-init, Artemis broker-runtime, and ZooKeeper tags independently. An OS
rebuild receives a new tag such as `3.9.5-os2`; its SBOM and vulnerability scan
remain attached to that build in the artifact system rather than duplicated in
the Platform Release manifest.

### 3. Preview and write the repository change

Every command is a dry run unless `--write` is explicitly supplied. Preview
one target:

```sh
./gitops/scripts/prepare-upgrade.sh \
  --component kubernetes \
  --version VERSION

./gitops/scripts/prepare-upgrade.sh \
  --component broker \
  --version VERSION \
  --chart-artifact /path/to/current-operator-chart.tgz

./gitops/scripts/prepare-upgrade.sh \
  --component zookeeper \
  --version VERSION
```

Operator upgrades use the unmodified upstream chart and no vendor rebase:

```sh
./gitops/scripts/prepare-upgrade.sh \
  --component operator \
  --version VERSION \
  --baseline-chart-artifact /path/to/current-chart.tgz \
  --chart-artifact /path/to/candidate-chart.tgz \
  --chart-oci-digest sha256:... \
  --manifest-sha256 HEX
```

The defaults are operator/ZooKeeper `VERSION` and broker `artemis.VERSION`.
For an OS-only rebuild, keep `--version` at the application version and pass
`--image-tag`, or the broker-specific `--init-image-tag` and
`--runtime-image-tag`, with the newly published immutable tag.

Review the exact configuration diff and the canonical full-render diff written
under `reports/`, then rerun the same command with `--write`. The render diff
contains every test, nonprod, and prod resource with deterministic resource and
mapping order so CRD, RBAC, selector, name, and related-image changes remain
visible. The command stages and validates all generated consumers before
copying them into the checkout. It does not download, mirror, commit, sync
Argo CD, or deploy.

The current operator chart is required for broker changes so validation can
prove its related-image inventory supports the requested broker version.
Historical labels on the ZooKeeper PVC template intentionally
remain unchanged because the complete claim template is immutable.

### 4. Validate and promote

1. Record immutable image tags, SBOM and license inventory, scan result, and
   the applicable compatibility matrix in the artifact promotion record.
2. Run `ARKMQ_UPSTREAM_CHART=/path/to/approved-chart.tgz make release-gate`
   with the renderer versions pinned in [`toolchain.yaml`](../../toolchain.yaml).
3. Promote the approved Git revision to test and
   run the required compatibility, durability, failure, credential-rotation,
   management-authorization, and load scenarios from
   [`tests/e2e/acceptance-plan.yaml`](../../tests/e2e/acceptance-plan.yaml).
4. Promote the same revision and immutable artifacts to nonprod. Run upgrade
   and rollback there, then obtain operational approval before prod.
5. Upgrade one ZooKeeper member at a time, then one Workload Cell or namespace
   at a time. Observe replication, queue depth, paging, disk, JVM, client
   reconnect, and Argo health between steps.

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
