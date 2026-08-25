# Repository structure and change guide

This is the contributor map for Artemis. Use it to choose the narrowest
authoritative file for a change instead of copying configuration between
layers.

## Configuration flow

Argo CD discovers enabled Workload Cells from one environment topology file.
For each cell, the generated Application renders the repository-owned Artemis
chart with values in this order:

1. `gitops/charts/artemis-ha/values.yaml` supplies chart defaults;
2. `gitops/argocd/profiles/<profile>/values.yaml` supplies reusable capability
   and operating-policy defaults;
3. `gitops/environments/<environment>/artemis-values.yaml` supplies
   cluster-wide integration values;
4. `gitops/workloads/<environment>/<workload-cell>/artemis-values.yaml`
   supplies pair-owned messaging and client policy; and
5. the ApplicationSet injects typed identity, sizing, feature, and enablement
   values from `gitops/argocd/topology/<environment>.yaml`.

Later layers win when Helm merges the same supported map field. The topology
validator also protects fields that a later layer is not allowed to own. Do
not work around that boundary by adding raw Helm parameters or duplicating a
setting in several layers.

## Where to make a change

| Change | Authoritative location | Also review or validate |
| --- | --- | --- |
| Add, enable, disable, resize, or rename a Workload Cell | `gitops/argocd/topology/<environment>.yaml` | Add or remove the matching workload values file; run `make validate-topology` and `make test-topology`. Retirement must follow the retirement runbook. |
| Change one cell's listeners, destinations, client CIDRs/selectors, or external authorization | `gitops/workloads/<environment>/<workload-cell>/artemis-values.yaml` | `gitops/workloads/README.md`, chart schema, chart and topology validation. |
| Change a cluster-wide storage class, label, Keycloak integration, ingress baseline, or network input | `gitops/environments/<environment>/artemis-values.yaml` | `gitops/environments/README.md`; keep release and image data out of this layer. |
| Add a reusable capability or approved feature switch | `gitops/argocd/profiles/<profile>/profile.yaml` and `values.yaml` | ApplicationSet typed parameters and topology validator/tests. Do not put identity, release, HA, durability, coordination, or cluster integration in a Profile. |
| Change Artemis resource behavior or add a supported chart value | `gitops/charts/artemis-ha/values.yaml`, `values.schema.json`, and `templates/` | Chart fixtures/tests, chart README, implementation spec, and relevant ADR. |
| Upgrade Kubernetes, ArkMQ, Artemis, or ZooKeeper | `gitops/releases/current.yaml` through `make prepare-upgrade` | Kustomize/chart consumers, provenance, upgrade runbook, `make release-gate`. Do not pin versions in environment or workload values. |
| Change common ArkMQ operator policy | `gitops/kustomize/arkmq-operator/base/` | Operator overlays/tests, toolchain pin, operator ADR. Prefer upstream chart values; patch only policy the chart cannot express. |
| Change environment-specific operator identity or private images | `gitops/kustomize/arkmq-operator/overlays/<environment>/` | Central release record and operator render/schema validation. |
| Change common ZooKeeper quorum, security, policy, or monitoring behavior | `gitops/kustomize/zookeeper/base/` | All overlays/tests, ZooKeeper README and ADR, manual rollout gate. Preserve resource and PVC identities. |
| Change ZooKeeper capacity, storage, placement input, or cluster integration | `gitops/kustomize/zookeeper/overlays/<environment>/` | Render all overlays and follow the controlled rollout guidance. |
| Change Argo project policy or child Application composition | `gitops/argocd/bootstrap/base/` | All bootstrap overlays, topology validation, Argo CD README and cluster-composition ADR. |
| Change one cluster's Argo namespace, Git source, ECR base, or adapter identity | `gitops/argocd/bootstrap/<environment>/` | Terraform handoff contract and full rendered bootstrap. |
| Change standalone developer behavior | `local/compose.yaml`, `.env.example`, or `local/scripts/` | `make validate-compose` and `local/README.md`. Never infer production behavior from Compose. |
| Change load shape or acceptance thresholds | `performance/profiles/sustained-load-profiles.yaml` | Runner and failure-harness tests; document what the evidence proves. |
| Change JMS client behavior | `performance/client/` | Unit tests, client README, and protocol evidence semantics in the performance guide. |
| Change artifact transfer automation | `jobs/ecr/` for the Jenkins seed; `resources/ecr/` for the pipeline and shell helper | Deferred ECR-mirroring guide and pipeline-owned validation. |
| Change validation behavior | Area-local `tests/` or `scripts/`; repository orchestration in `scripts/` and the root `Makefile` | Keep `make validate` as the complete entry point and update the relevant guide. |
| Change a design decision | The applicable ADR under `gitops/docs/` | Implementation, tests, operational guide, and `CONTEXT.md` vocabulary if terminology changes. |
| Add or revise operating instructions | `gitops/docs/runbooks/` | GitOps documentation index and the executable scripts/commands the runbook cites. |

## Directory ownership

```text
Artemis/
├── README.md                    Repository entry point and safety boundary
├── CONTEXT.md                   Platform vocabulary
├── docs/                        Repository-wide contributor guidance
├── gitops/
│   ├── argocd/                  Cluster composition, topology, and Profiles
│   ├── charts/artemis-ha/       Repository-owned Workload Cell chart
│   ├── environments/            Environment-wide Artemis values
│   ├── kustomize/               ArkMQ operator and ZooKeeper deployments
│   ├── releases/                Central Platform Release record
│   ├── workloads/               Per-Workload-Cell values
│   ├── scripts/ and tests/      GitOps rendering and contract checks
│   └── docs/                    Design, integration, migration, and runbooks
├── local/                       Standalone Compose development broker
├── performance/                 Deterministic validation client and profiles
├── jobs/ and resources/         Deferred Jenkins/ECR transfer automation
├── scripts/                     Whole-repository validation
└── reports/                     Generated, ignored validation evidence
```

## Documentation lifecycle

Documentation must declare its role through the
[GitOps documentation index](../gitops/docs/README.md): authoritative design,
how-to guide, runbook, proposal, or non-authoritative research. Accepted design
belongs in an ADR; a proposal or research note must not silently become the
source of truth.

Remove completed one-time migration checklists after their instructions are
encoded in the current guides and validation. Keep durable migration guides
only while they describe a supported source system or an active transition.
When implementation changes, update the closest README and any affected ADR or
runbook in the same change.

Never place credentials, private keys, account IDs, real cluster names,
internal domains, message bodies, or unsanitized live evidence in documentation
or examples.

## Contributor workflow

1. Read `CONTEXT.md`, this guide, the closest area README, and applicable ADRs.
2. Make the change in one authoritative layer and update adjacent tests/docs.
3. Run the narrow validation targets listed above.
4. Run `make validate-docs` and `git diff --check`.
5. Before release, run `make validate`; release changes also require the
   artifact-backed `make release-gate`.

Live verification and deployment are separate, authorized work-computer steps.
Repository validation proves rendered intent; it does not prove live cluster
state.
