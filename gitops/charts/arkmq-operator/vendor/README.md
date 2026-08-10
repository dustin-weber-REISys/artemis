# Vendored ArkMQ chart

`arkmq-org-broker-operator` chart version `2.2.0-enterprise.4` is generated
from the public Quay `2.2.0` chart plus the ordered patches in [`patches`](patches).
[`upstream.lock.yaml`](upstream.lock.yaml) records both the OCI manifest digest
and the SHA-256 checksum of the downloaded chart package. The distinct version
prevents a dependency cache from substituting the unpatched upstream package:

The package checksum was calculated from the exact `helm pull` artifact whose
OCI manifest digest is recorded in the lock. OCI and package digests describe
different byte streams, so both are retained and neither should be substituted
for the other.

- `_helpers.tpl` defines `requiredLabels` and includes them in resource labels.
- `deployment.yaml` includes `requiredLabels` on the pod template.
- `deployment.yaml` uses the replacement identity
  `activemq-artemis-controller-manager-v2` and a stable two-label selector.
- The `2.53.0` related-image values accept an optional tag so a private mirror
  is never paired with a digest that exists only in the upstream registry.

The new identity lets Argo CD create a valid Deployment regardless of which
immutable selector an earlier revision installed, then prune the obsolete
Deployment. The wrapper PDB uses the same stable `control-plane` and `name`
pair. Required enterprise labels remain metadata-only. The original chart
digest is recorded in the wrapper README.

Do not edit `arkmq-org-broker-operator` directly. Obtain the exact upstream
package on a connected workstation, then prepare and compare it offline:

```sh
helm pull oci://quay.io/arkmq-org/helm-charts/arkmq-org-broker-operator \
  --version 2.2.0 \
  --destination /tmp

gitops/scripts/vendor-check.sh \
  --artifact /tmp/arkmq-org-broker-operator-2.2.0.tgz
```

For an upgrade, create the new lock and patches first, then generate a review
copy into a new directory:

```sh
gitops/scripts/prepare-arkmq-vendor.sh \
  --artifact /tmp/arkmq-org-broker-operator-NEW.tgz \
  --output /tmp/arkmq-enterprise-review
```

The preparation command refuses an existing output directory. This preserves
the committed copy until the generated diff has been reviewed. Each enterprise
change belongs in a named patch, and `enterprise.version` must be incremented
whenever the patch output changes.
