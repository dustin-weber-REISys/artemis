# Helm and Kustomize authoring guidance

Research date: 2026-08-24  
Scope: official Helm documentation and Kubernetes/Kustomize documentation or
source only. Repository-specific conclusions are identified as inference.

## Short answer

Official guidance supports keeping user-facing configuration in `values.yaml`,
validating the final merged values with `values.schema.json`, putting reusable
template implementation in namespaced partials, and keeping each rendered
Kubernetes resource in its own clearly named template file. It also supports a
Kustomize base/overlay layout in which a base is reusable and has no knowledge
of its overlays.

The guidance does **not** imply that all repeated policy should become a new
chart dependency or shared Kustomize transformer. In this repository, candidate
1 can improve locality at the existing Workload Cell authoring seam. Candidate
3 cannot be centralized safely inside the current Kustomize composition without
either changing ordering semantics or disabling the default file-loading
restriction.

## Explicit Helm guidance

- A chart's conventional file structure assigns distinct roles to
  `Chart.yaml`, `values.yaml`, optional `values.schema.json`, `charts/`, and
  `templates/`. `values.schema.json` imposes structure on chart values, while
  `templates/` produces Kubernetes manifests. ([Charts](https://helm.sh/docs/topics/charts/))
- Values should use lower camel case. Helm generally favors flat values because
  they are easier to override and require fewer existence checks; nested values
  remain reasonable for a large related group when at least one member is
  required. Authors should design values for both values files and `--set`
  usage. ([Values best practices](https://helm.sh/docs/chart_best_practices/values/))
- YAML-producing templates should use `.yaml`; non-output partials may use
  `.tpl`. Each resource definition should have its own file, and the dashed file
  name should reflect the resource kind. Named templates are globally visible
  across a chart and its subcharts, so their names must be namespaced.
  ([Template best practices](https://helm.sh/docs/chart_best_practices/templates/))
- Files beginning with `_` do not render manifests and are the conventional
  home for reusable partials, commonly `_helpers.tpl`.
  ([Named templates](https://helm.sh/docs/chart_template_guide/named_templates/))
- A `values.schema.json` schema validates the **final** merged `.Values` object,
  including user overrides, during `helm install`, `helm upgrade`, `helm lint`,
  and `helm template`. Subchart schemas are also enforced against final values.
  ([Schema files](https://helm.sh/docs/topics/charts/#schema-files))
- True chart dependencies belong in `Chart.yaml` or `charts/`. Optional
  dependencies should use conditions or tags; `file://` dependencies are a
  special case for fixed deployment pipelines.
  ([Dependency best practices](https://helm.sh/docs/chart_best_practices/dependencies/))
- For a complex application composed of discrete parts, Helm recommends an
  umbrella chart with subcharts. This guidance concerns independently packaged
  chart parts, not merely sharing template logic inside one chart.
  ([Chart development tips](https://helm.sh/docs/howto/charts_tips_and_tricks/#complex-charts-with-many-dependencies))

## Explicit Kubernetes and Kustomize guidance

- A base contains reusable resources and customization and has no knowledge of
  an overlay. An overlay refers to one or more bases and applies customization
  on top of their accumulated resources.
  ([Kubernetes Kustomize guide](https://kubernetes.io/docs/tasks/manage-kubernetes-objects/kustomization/#bases-and-overlays))
- `configMapGenerator` and `secretGenerator` generate resources from files or
  literals. Generated names normally include a content hash, and Kustomize
  updates recognized references to those names.
  ([Kubernetes Kustomize guide](https://kubernetes.io/docs/tasks/manage-kubernetes-objects/kustomization/#generating-resources))
- `replacements` copies a selected source field into selected target fields and
  is the documented mechanism for avoiding hard-coded values such as a name
  changed by `namePrefix` or `nameSuffix`.
  ([Kubernetes replacements example](https://kubernetes.io/docs/tasks/manage-kubernetes-objects/kustomization/#composing-and-customizing-resources))
- Patches listed in one `patches` field are applied in list order.
  ([Kustomize `patches` reference](https://github.com/kubernetes-sigs/kustomize/blob/master/site/content/en/docs/Reference/API/Kustomization%20File/patches.md))
- In the v5.8.1 implementation, each Kustomization recursively accumulates its
  resources, then runs generators, accumulates components, runs transformers,
  and finally runs validators. Built-in transformers run before explicitly
  configured external transformers.
  ([Kustomize v5.8.1 target implementation](https://github.com/kubernetes-sigs/kustomize/blob/kustomize/v5.8.1/api/internal/target/kusttarget.go))
- Kustomize describes generators as producing Kubernetes YAML and transformers
  as modifying it. Built-in behavior can be invoked through the concise
  Kustomization fields or through fully configured `generators:` and
  `transformers:` entries.
  ([Builtin plugin configuration](https://github.com/kubernetes-sigs/kustomize/blob/master/examples/configureBuiltinPlugin.md))
- Upstream recommends keeping referenced Helm material in or below the
  Kustomization directory. Referencing material outside that root fails unless
  `--load-restrictor=none` is used, which disables file-loading restrictions.
  ([Kustomize Helm example](https://github.com/kubernetes-sigs/kustomize/blob/master/examples/chart.md))

## Repository-specific inferences

These conclusions follow from the official behavior above and the local
experiment; they are not direct Helm or Kustomize prescriptions.

1. `values.schema.json` is the strongest existing interface for chart-facing
   configuration. Structural constraints should be expressed there when
   possible, while cross-resource semantic rules that JSON Schema cannot state
   clearly should remain behind a namespaced chart-internal helper or the
   repository validator.
2. Deepening chart policy should not collapse several rendered resources into
   one large template. Separate resource files preserve Helm's recommended
   authoring shape; shared normalization and validation can sit behind an
   internal helper seam.
3. A chart dependency is justified when there is an independently packaged
   chart module. It is too heavy an interface for merely deduplicating policy
   inside the existing Artemis chart.
4. A replacement must run at the Kustomization level that can see the final
   source value it needs. A replacement inside a child base is part of that
   child's implementation and completes before an outer overlay patch changes
   the accumulated resource.
5. Disabling the load restriction to share one sibling transformer increases
   the filesystem surface every renderer must trust and makes correct rendering
   depend on a non-default CLI interface. Exact output equivalence alone does
   not remove that operational cost.

## Local Kustomize v5.8.1 experiment

This experiment was performed in
`/private/tmp/artemis-kustomize-experiment.Oybrz7`; it did not modify the
repository. No standalone `kustomize` was installed. `kubectl` v1.36.1 supplied
embedded Kustomize v5.8.1, matching `gitops/toolchain.yaml`.

### Baseline

Unchanged stable-root output SHA-1 values were:

| Root | SHA-1 |
| --- | --- |
| `test` | `421dcfe1f94f43415856c9b2cf25d8b18a4dd68b` |
| `nonprod` | `8333d6a4620c31248a56e087c31895c70d0683dd` |
| `prod` | `735ae84a645f67abd6f41e174308b57ca27c3771` |

### Experiment 1: replacements in `bootstrap/base`

Rendering completed but was not semantically equivalent. Replacements ran
before the outer cluster patch, so dependent names and paths retained base
placeholders such as `cluster`, `main`, and `topology/cluster.yaml`. Simulated
root revision injection changed the AppProject annotation to
`upgrade/platform-release`, but child revisions and the ApplicationSet
generator remained `main`.

### Experiment 2: shared Kustomize Component

Rendering again completed but produced the same semantic failure. Component
accumulation did not provide the needed ordering relative to the parent root's
patches and replacements.

### Experiment 3: shared top-level `ReplacementTransformer`

At the correct root level, the transformer had the required ordering, but the
default build rejected its sibling path with a `security; file ... is not in or
below ...` error. With `--load-restrictor LoadRestrictionsNone`, all three
renders were byte-identical to baseline and retained the baseline hashes above.

The simulated root revision case was also byte-identical between the baseline
and shared-transformer shapes, with SHA-1
`38dc425968bad8ab289f97d424be5f32ec813b47`; the AppProject, child
Applications, ApplicationSet generator, and generated Workload Cell source all
selected `upgrade/platform-release`.

Adopting that shape would require the relaxed option in Argo, local validation,
CI, and tests. The repository currently records only `--enable-helm` for Argo,
and its render scripts use the default load restriction.

## Candidate recommendation matrix

| Question | Candidate 1: deepen the Workload Cell authoring-policy module | Candidate 3: deepen shared bootstrap propagation |
| --- | --- | --- |
| Intended seam | Keep topology/profile authoring as the external seam; concentrate rules behind its existing validation interface. | Keep each stable bootstrap root as the external seam; attempt to concentrate replacement implementation behind it. |
| Official-guidance fit | Good, if chart-facing structure remains in `values.schema.json`, templates remain resource-oriented, and reusable implementation stays internal. | Mixed. Shared base logic fits base/overlay reuse, but the required source value is owned by the overlay and therefore arrives too late for base- or Component-owned replacements. |
| Locality | Improves when field meaning, ownership, validation, and test fixtures are derived from one authoritative policy module rather than repeated across shell and prose. | Text locality improves only with a shared top-level transformer; default-restricted Kustomize cannot load that sibling file from all three roots. |
| Leverage | One policy implementation can support validation, editor guidance, tests, and documentation while retaining the same authoring interface. | One implementation would serve three roots, but every renderer must learn a broader non-default interface and its security implication. |
| Test surface | Preserve topology validation and fully rendered ApplicationSet/chart output as the test surface. | Preserve fully rendered bootstrap output and root revision propagation as the test surface; hashes prove equivalence only under `LoadRestrictionsNone`. |
| Deletion test | Deleting the proposed module would spread the same rules back across validators, schema, tests, and documentation, so the module can earn depth. | Deleting a root-local replacement block leaves two copies; each copy is shallow. However, the feasible shared module adds a load-restriction requirement to its interface. |
| Recommendation | **Proceed, narrowly.** Deepen the existing authoring-policy module without adding a new chart dependency or a second topology representation. | **Do not centralize through `LoadRestrictionsNone`.** Keep root-local replacements and add or retain a drift/equivalence check; consider mechanical synchronization only if the duplication becomes materially costly. |

## Conclusion

Candidate 1 has the stronger architectural case. It can improve locality and
leverage while preserving Helm's chart structure, Kustomize's authoring seam,
and rendered output as the test surface. Candidate 3 demonstrates real textual
duplication, but the tested deep module either runs at the wrong time or expands
the renderer interface by disabling a default restriction. For the current
three roots, explicit local replacements plus render-level drift protection are
the safer tradeoff.
