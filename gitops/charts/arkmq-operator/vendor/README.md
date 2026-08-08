# Vendored ArkMQ chart

`arkmq-org-broker-operator` chart version `2.2.0-enterprise.1` is copied from
the public Quay `2.2.0` chart with four intentional template changes. The
distinct version prevents a dependency cache from substituting the unpatched
upstream package:

- `_helpers.tpl` defines `requiredLabels` and includes them in resource labels.
- `_helpers.tpl` defines the eight-label legacy Deployment selector separately
  from the chart's ordinary selector-label helper.
- `deployment.yaml` includes `requiredLabels` on the pod template.
- `deployment.yaml` reproduces the selector stored by existing installations:
  `control-plane`, `name`, Helm name/instance, and the four enterprise labels.

This lets Argo CD update the existing Deployment without attempting an
immutable selector change. The wrapper PDB remains on the stable
`control-plane` and `name` pair. The four enterprise selector keys are
enumerated explicitly so future metadata-only labels do not expand the
immutable selector. The original chart digest is recorded in the wrapper
README.
