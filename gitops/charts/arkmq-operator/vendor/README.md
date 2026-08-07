# Vendored ArkMQ chart

`arkmq-org-broker-operator` 2.2.0 is copied from the public Quay chart with three
intentional template changes:

- `_helpers.tpl` defines `requiredLabels` and includes them in resource labels,
  but not selector labels.
- `deployment.yaml` includes `requiredLabels` on the pod template.
- `deployment.yaml` keeps its immutable selector limited to the legacy
  `control-plane` and `name` labels; the wrapper PDB uses the same stable pair.

This keeps Helm release and operator labels configurable without changing the
immutable Deployment selector of an existing installation. The original chart
digest is recorded in the wrapper README.
