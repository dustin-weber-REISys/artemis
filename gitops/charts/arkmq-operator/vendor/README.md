# Vendored ArkMQ chart

`arkmq-org-broker-operator` 2.2.0 is copied from the public Quay chart with two
intentional template changes:

- `_helpers.tpl` defines `requiredLabels` and includes them in resource labels,
  but not selector labels.
- `deployment.yaml` includes `requiredLabels` on the pod template.

This keeps the operator labels configurable without changing the immutable
Deployment selector. The original chart digest is recorded in the wrapper
README.
