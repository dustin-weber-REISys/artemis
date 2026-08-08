# Vendored ArkMQ chart

`arkmq-org-broker-operator` chart version `2.2.0-enterprise.2` is copied from
the public Quay `2.2.0` chart with three intentional template changes. The
distinct version prevents a dependency cache from substituting the unpatched
upstream package:

- `_helpers.tpl` defines `requiredLabels` and includes them in resource labels.
- `deployment.yaml` includes `requiredLabels` on the pod template.
- `deployment.yaml` uses the replacement identity
  `activemq-artemis-controller-manager-v2` and a stable two-label selector.

The new identity lets Argo CD create a valid Deployment regardless of which
immutable selector an earlier revision installed, then prune the obsolete
Deployment. The wrapper PDB uses the same stable `control-plane` and `name`
pair. Required enterprise labels remain metadata-only. The original chart
digest is recorded in the wrapper README.
