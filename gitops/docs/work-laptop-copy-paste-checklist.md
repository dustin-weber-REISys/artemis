# Work-laptop GitHub UI copy/paste checklist

Use this one-time change checklist when the work laptop can view repository
files and diffs in the GitHub UI but cannot clone or download them. Copy only
the reviewed plain-text files listed below. Remove this checklist from the
work-laptop directory after the change record is complete.

## Change record

- [ ] Record the GitHub repository, branch, and commit being copied.
- [ ] Record the date, change ticket, and reviewer required by local policy.
- [ ] Confirm the GitHub diff contains no credentials or environment values.
- [ ] Keep actual placeholder substitutions only on the work laptop.
- [ ] If the directory has Git metadata, save `git status --short` and
      `git diff --name-status` before editing.

GitHub repository: `____________________`

Branch or commit: `____________________`

Change ticket: `____________________`

Reviewer: `____________________`

## Protect the work-laptop configuration

- [ ] Back up each existing file to an approved location outside the tracked
      checkout before editing it.
- [ ] Use GitHub's **Files changed** view for existing files; do not replace a
      whole operational file with its repository-template version.
- [ ] Preserve locally resolved values in these files:

  - `gitops/argocd/bootstrap/test/operator-application.yaml`
  - `gitops/argocd/bootstrap/nonprod/operator-application.yaml`
  - `gitops/argocd/bootstrap/prod/operator-application.yaml`
  - `gitops/charts/arkmq-operator/values.yaml`
  - `gitops/charts/artemis-ha/values.yaml`
  - `resources/ecr/ecrHelmChartTransfer.groovy`

- [ ] Preserve any other work-owned values, URLs, image repositories, digests,
      namespaces, storage classes, secret names, Jenkins labels, imports, and
      shared-library names encountered during review.
- [ ] Never paste real work values back into GitHub, a ticket, or this checklist.

## Create these new files

For each file, use the GitHub **Raw** view, copy all text, create the same path
on the work laptop, paste, save, and review the first and last lines.

- [ ] `gitops/charts/arkmq-operator/vendor/patches/0001-required-admission-labels.patch`
- [ ] `gitops/charts/arkmq-operator/vendor/patches/0002-replacement-deployment-identity.patch`
- [ ] `gitops/charts/arkmq-operator/vendor/patches/0003-private-mirror-tags.patch`
- [ ] `gitops/charts/arkmq-operator/vendor/upstream.lock.yaml`
- [ ] `gitops/releases/current.yaml`
- [ ] `gitops/scripts/collect-artemis-evidence.sh`
- [ ] `gitops/scripts/prepare-arkmq-vendor.sh`
- [ ] `gitops/scripts/prepare-upgrade.sh`
- [ ] `gitops/scripts/validate-release.sh`
- [ ] `gitops/scripts/validate-rendered-schema.sh`
- [ ] `gitops/scripts/vendor-check.sh`

The three files ending in `.patch` are readable source transformations for the
vendored ArkMQ chart. They are not repository-transfer patches and are never
applied to the work-laptop checkout. `prepare-arkmq-vendor.sh` applies them only
to a checksum-locked upstream chart in a temporary directory during a future
operator rebase.

## Merge these existing files

Apply only the additions and removals shown in GitHub's **Files changed** view.
Review every deletion before saving.

### Version source, commands, and validation

- [ ] `Makefile`
- [ ] `README.md`
- [ ] `scripts/validate-repository.sh`
- [ ] `gitops/Makefile`
- [ ] `gitops/README.md`
- [ ] `scripts/validate-static.sh`
- [ ] `gitops/scripts/validate-charts.sh`
- [ ] `gitops/scripts/validate-operator-schema.sh`
- [ ] `gitops/scripts/validate-scenarios.sh`
- [ ] `gitops/scripts/validate-topology.sh`
- [ ] `gitops/scripts/verify-argocd-applicationset.sh`

### Argo CD and Helm consumers

- [ ] `gitops/argocd/README.md`
- [ ] `gitops/argocd/bootstrap/test/operator-application.yaml`
- [ ] `gitops/argocd/bootstrap/nonprod/operator-application.yaml`
- [ ] `gitops/argocd/bootstrap/prod/operator-application.yaml`
- [ ] `gitops/charts/arkmq-operator/values.yaml`
- [ ] `gitops/charts/arkmq-operator/README.md`
- [ ] `gitops/charts/arkmq-operator/vendor/README.md`
- [ ] `gitops/charts/artemis-ha/templates/activemqartemis.yaml`
- [ ] `gitops/charts/artemis-ha/values.schema.json`
- [ ] `gitops/charts/artemis-ha/values.yaml`
- [ ] `resources/ecr/ecrHelmChartTransfer.groovy`

The operator Applications should retain their local repository, revision,
namespace, and ECR substitutions. Remove only the duplicated version/tag
overrides shown by the diff; the wrapper chart now owns those versions.

### Tests

- [ ] `gitops/charts/arkmq-operator/tests/test.sh`
- [ ] `gitops/charts/artemis-ha/tests/test.sh`
- [ ] `gitops/charts/zookeeper/tests/test.sh`
- [ ] `gitops/tests/argocd/test-verify-applicationset.sh`
- [ ] `gitops/tests/chart/validation-policy.yaml`
- [ ] `gitops/tests/topology/test.sh`

### Documentation

- [ ] `gitops/charts/artemis-ha/README.md`
- [ ] `gitops/docs/environment-import-walkthrough.md`
- [ ] `gitops/docs/helm-ecr-mirroring.md`
- [ ] `gitops/docs/runbooks/broker-reconciliation-debugging.md`
- [ ] `gitops/docs/runbooks/install-verification.md`
- [ ] `gitops/docs/runbooks/upgrade-rollback.md`

## File permissions

Text pasted into a newly created file may not retain the executable bit. Run
this only for the new shell scripts listed above:

```sh
chmod +x \
  gitops/scripts/collect-artemis-evidence.sh \
  gitops/scripts/prepare-arkmq-vendor.sh \
  gitops/scripts/prepare-upgrade.sh \
  gitops/scripts/validate-release.sh \
  gitops/scripts/validate-rendered-schema.sh \
  gitops/scripts/vendor-check.sh
```

- [ ] Confirm the six new shell scripts are executable.

## Repository-only validation

These commands inspect local files and run local tests. They do not query the
live Kubernetes cluster.

```sh
make versions
gitops/scripts/validate-release.sh
ARTEMIS_SCHEMA_MODE=offline make validate
git diff --check
git status --short
```

- [ ] `make versions` reports the intended Kubernetes, operator, broker, and
      ZooKeeper versions from `gitops/releases/current.yaml`.
- [ ] Release validation passes.
- [ ] All repository validation checks pass.
- [ ] Review unresolved operational placeholders without putting their values
      into command output that will be shared externally:

```sh
rg -n 'PLACEHOLDER_|example\.invalid' \
  gitops/argocd/bootstrap/test/operator-application.yaml \
  gitops/argocd/bootstrap/nonprod/operator-application.yaml \
  gitops/argocd/bootstrap/prod/operator-application.yaml \
  gitops/charts/arkmq-operator/values.yaml \
  gitops/charts/artemis-ha/values.yaml \
  resources/ecr/ecrHelmChartTransfer.groovy
```

- [ ] Every operational placeholder reported above is intentional or resolved.

## Read-only live ApplicationSet verification

Run this section only from the authorized work laptop with the intended
read-only Kubernetes context. The verifier reads the selected local topology
file and makes `kubectl get` calls to the live cluster. It does not compare the
entire work repository with GitHub.

```sh
./gitops/scripts/verify-argocd-applicationset.sh \
  --context WORK_CONTEXT \
  --argocd-namespace WORK_ARGOCD_NAMESPACE \
  --environment test
```

Repeat with `nonprod` or `prod` only when authorized.

The verifier uses `bash`, read-only `kubectl get`, and `yq`. It compares the
selected local topology with live state and reports reconciled Git revisions;
review revision drift before promotion. See the
[broker reconciliation runbook](runbooks/broker-reconciliation-debugging.md)
for its exact checks and failure ownership.

- [ ] Confirm the selected context and environment before running it.
- [ ] Confirm the result ends with `Live Artemis health: PASS`.
- [ ] Save the output in the approved ticket or evidence location.
- [ ] If it fails, collect read-only evidence using the companion runbook; do
      not deploy or mutate the cluster as part of verification.

## Completion

- [ ] Placeholder values remained local and unchanged.
- [ ] Central release validation passed.
- [ ] Complete offline repository validation passed.
- [ ] Authorized live verification passed, or its failure evidence is attached.
- [ ] A second engineer reviewed the manually merged operational files.
- [ ] The GitHub commit and local completion evidence are recorded in the
      change ticket.
