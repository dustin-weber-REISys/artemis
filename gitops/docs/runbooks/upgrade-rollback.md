# Upgrade and rollback

Promote the exact tested image and chart digests. Treat Kubernetes, operator,
broker, ZooKeeper, and client-library changes as separate observed Platform
Release changes. The operating system inside every promoted container image is
part of that image's release evidence, not the EKS worker-node configuration.

> This repository is an offline/test copy. Run registry, Kubernetes, and Argo CD
> steps below only from the authorized work computer and approved
> contexts. The repository commands are local, deterministic, and do not deploy.

## Upgrade

### 1. Select one change

Review the centrally selected Platform Release:

```sh
make versions
```

Replace every image-OS placeholder with `ID` and `VERSION_ID` read from
`/etc/os-release` in the exact digest-qualified image before the first
promotion. Use one pull request and change window per row:

| Component | Required preview inputs | Repository-owned result |
| --- | --- | --- |
| Kubernetes | semantic version | central platform assumption used by schema validation |
| Operator | chart artifact and provenance; image digest and OS identity | central version/provenance plus every operator overlay |
| Broker | version, current operator chart, and separate init/runtime OS identities | central version, chart schema/default, related-image mappings, and image OS records |
| ZooKeeper | version, immutable image digest, and image OS identity | central version, pod labels, image references, and image OS record |

Do not combine control-plane, operator, operand, or client changes
just because they are mutually compatible. Separate changes preserve a useful
rollback boundary.

### 2. Record artifact and live baselines

Run the approved ECR image/chart transfer jobs first. Record their build URLs
and fingerprinted promotion records; the target artifacts must already exist in
the immutable destination repositories. Inspect each exact destination digest,
not a mutable tag or an upstream Dockerfile:

```sh
docker pull REGISTRY/IMAGE@sha256:DIGEST
./gitops/scripts/read-image-os.sh \
  --image REGISTRY/IMAGE@sha256:DIGEST \
  --format args
```

Run this independently for the operator, Artemis broker-init, Artemis broker
runtime, and ZooKeeper images. If an image has no `/etc/os-release`, stop and
record that exception from its SBOM rather than guessing a distribution. The
SBOM, vulnerability scan, signature, digest, and OS identity must all describe
the same image manifest and architecture. The helper creates a stopped
temporary container only to copy `/etc/os-release`; it never runs the image and
removes the container on exit.

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
  --chart-artifact /path/to/current-operator-chart.tgz \
  --init-image-digest sha256:... \
  --runtime-image-digest sha256:... \
  --init-image-os-id ID \
  --init-image-os-version VERSION_ID \
  --runtime-image-os-id ID \
  --runtime-image-os-version VERSION_ID

./gitops/scripts/prepare-upgrade.sh \
  --component zookeeper \
  --version VERSION \
  --image-digest sha256:... \
  --image-os-id ID \
  --image-os-version VERSION_ID
```

Operator upgrades use the unmodified upstream chart and no vendor rebase:

```sh
./gitops/scripts/prepare-upgrade.sh \
  --component operator \
  --version VERSION \
  --chart-artifact /path/to/chart.tgz \
  --chart-oci-digest sha256:... \
  --manifest-sha256 HEX \
  --image-digest sha256:... \
  --image-os-id ID \
  --image-os-version VERSION_ID
```

Review the exact diff, then rerun the same command with `--write`. The command
stages and validates all generated consumers before copying them into the
checkout. It does not download, mirror, commit, sync Argo CD, or deploy.

The current operator chart is required for broker changes so validation can
prove its related-image inventory supports the requested broker version. A
ZooKeeper tag change without the matching digest does not change the image that
Kubernetes runs. Historical labels on the ZooKeeper PVC template intentionally
remain unchanged because the complete claim template is immutable.

### 4. Validate and promote

1. Record source versions, immutable digests, `/etc/os-release` identity, SBOM,
   license inventory, scan result, and the applicable compatibility matrix.
2. Run the canonical repository validation from the root
   [`README`](../../README.md#validate).
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
