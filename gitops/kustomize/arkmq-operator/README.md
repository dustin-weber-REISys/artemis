# ArkMQ operator Kustomize deployment

Argo CD inflates the unmodified public
`arkmq-org-broker-operator` Helm chart and then applies the repository-owned
Kustomize base and environment overlay. The upstream chart is never copied,
forked, or patched in this repository.

The common [`base`](base) owns the platform-wide contract:

- the exact upstream chart repository and version;
- operator HA, scheduling, scope, and CRD Helm values;
- metadata-only admission labels;
- the stable replacement Deployment identity and selector; and
- the operator PodDisruptionBudget.

The base points every upstream related-image mapping at an intentionally
unreachable registry. The [`overlays`](overlays) own only the environment label
and replace the centrally approved broker/init mappings with final private ECR
image references. This fails closed if an unapproved broker version is created.
Argo CD must enable Helm inflation for Kustomize with
`kustomize.buildOptions: --enable-helm` (or the equivalent version-specific
setting).

## Render and validate

On a connected workstation, render directly from the public OCI chart:

```sh
gitops/scripts/render-arkmq-operator.sh --environment test > /tmp/operator.yaml
```

For an offline or supply-chain verification, first obtain the exact approved
chart package and pass it explicitly. The renderer verifies its SHA-256 against
[`releases/current.yaml`](../../releases/current.yaml) before Kustomize uses it:

```sh
helm pull oci://quay.io/arkmq-org/helm-charts/arkmq-org-broker-operator \
  --version 2.2.0 --destination /tmp

gitops/scripts/render-arkmq-operator.sh \
  --environment test \
  --artifact /tmp/arkmq-org-broker-operator-2.2.0.tgz \
  > /tmp/operator.yaml
```

The renderer stages a disposable copy so Helm chart downloads never modify the
checkout. Chart upgrades change the pinned version and provenance, then render
all three overlays to prove the object-level customizations still apply.
