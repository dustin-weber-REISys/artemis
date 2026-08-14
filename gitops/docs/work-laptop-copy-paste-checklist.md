# Work-laptop GitHub UI copy/paste checklist

Use this one-time checklist when the work laptop can view repository files and
diffs in GitHub but cannot clone or download them. Record the repository,
commit, change ticket, reviewer, and the pre-change `git status --short` before
editing. Preserve resolved work values and never paste them back into GitHub.

## Platform prerequisite

- [ ] Confirm the Argo CD administrators approved and applied
      `kustomize.buildOptions: --enable-helm`, or the equivalent
      version-specific setting.
- [ ] Confirm repo-server can pull the pinned public ArkMQ OCI chart.
- [ ] Confirm Argo CD uses the Kustomize and Helm versions pinned in
      `gitops/toolchain.yaml` and supports Helm OCI sources.

## Create the Kustomize deployment

Copy these directories and files from GitHub using the **Raw** view:

- [ ] `gitops/kustomize/arkmq-operator/base/kustomization.yaml`
- [ ] `gitops/kustomize/arkmq-operator/base/values.yaml`
- [ ] `gitops/kustomize/arkmq-operator/base/deployment-identity.patch.yaml`
- [ ] `gitops/kustomize/arkmq-operator/base/pdb.yaml`
- [ ] `gitops/kustomize/arkmq-operator/overlays/test/*`
- [ ] `gitops/kustomize/arkmq-operator/overlays/nonprod/*`
- [ ] `gitops/kustomize/arkmq-operator/overlays/prod/*`
- [ ] `gitops/kustomize/arkmq-operator/README.md`
- [ ] `gitops/kustomize/arkmq-operator/tests/test.sh`
- [ ] `gitops/scripts/render-arkmq-operator.sh`
- [ ] `gitops/scripts/diff-arkmq-operator.sh`
- [ ] `gitops/scripts/validate-toolchain.sh`
- [ ] `gitops/toolchain.yaml`

Preserve the fixed `artemis-platform` namespace, contact/FISMA labels, and
nonprod or production ECR bases when creating these files on the work laptop.

## Merge the integration changes

Apply only the reviewed additions and removals from GitHub's **Files changed**
view:

- [ ] `gitops/argocd/bootstrap/base/*`
- [ ] `gitops/argocd/bootstrap/test/*`
- [ ] `gitops/argocd/bootstrap/nonprod/*`
- [ ] `gitops/argocd/bootstrap/prod/*`
- [ ] `gitops/argocd/catalogs/*`
- [ ] `gitops/argocd/catalogs/*`
- [ ] `gitops/argocd/profiles/standard/*`
- [ ] `gitops/argocd/workload-cell-baseline.yaml`
- [ ] `gitops/releases/current.yaml`
- [ ] `gitops/scripts/prepare-upgrade.sh`
- [ ] `gitops/scripts/validate-release.sh`
- [ ] `gitops/scripts/validate-operator-schema.sh`
- [ ] `gitops/scripts/validate-topology.sh`
- [ ] `gitops/scripts/compose-topology.sh`
- [ ] `gitops/tests/catalogs/test.sh`
- [ ] `scripts/validate-static.sh`
- [ ] `scripts/validate-repository.sh`
- [ ] `Makefile` and `gitops/Makefile`
- [ ] GitOps READMEs, upgrade runbook, import walkthrough, and ECR mirroring guide

The rendered operator Applications must keep their identities, local Git URL,
root-injected revision, Argo namespace, destination namespace, sync policy,
and `PruneLast=true`. Do not recreate copied child manifests in the adapters.

## Remove the obsolete vendor implementation

After the Kustomize files and Applications have been reviewed:

- [ ] Remove `gitops/charts/arkmq-operator` in full, including the generated
      chart archive, vendor tree, source patches, and wrapper chart.
- [ ] Remove `gitops/scripts/prepare-arkmq-vendor.sh`.
- [ ] Remove `gitops/scripts/vendor-check.sh`.

These deletions are intentional. The unmodified chart now comes directly from
the pinned upstream OCI reference, and repository-owned behavior lives in the
Kustomize base and overlays.

## Permissions and validation

```sh
chmod +x \
  gitops/scripts/render-arkmq-operator.sh \
  gitops/kustomize/arkmq-operator/tests/test.sh

helm pull oci://quay.io/arkmq-org/helm-charts/arkmq-org-broker-operator \
  --version 2.2.0 --destination /tmp

export ARKMQ_UPSTREAM_CHART=/tmp/arkmq-org-broker-operator-2.2.0.tgz
make versions
make validate-release
make validate-operator-kustomize
make release-gate
ARTEMIS_SCHEMA_MODE=offline make validate
git diff --check
git status --short
```

- [ ] The chart checksum matches `gitops/releases/current.yaml`.
- [ ] All three overlays render the stable `-v2` Deployment, required labels,
      PDB, scheduling policy, and approved private images.
- [ ] Repository validation passes.
- [ ] A second engineer reviewed the resolved placeholders and deletions.

## Authorized live verification

From the authorized work laptop, run the existing read-only verifier only
against the intended context:

```sh
./gitops/scripts/verify-argocd-applicationset.sh \
  --context WORK_CONTEXT \
  --argocd-namespace argocd \
  --environment test
```

Repeat for nonprod or prod only when authorized. Confirm the operator
Application is `Synced/Healthy`, save the approved evidence, and stop promotion
if Argo reports a manifest-generation or Kustomize/Helm error.
