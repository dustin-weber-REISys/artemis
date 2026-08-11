# ADR: Shared Kustomize cluster composition

- Status: Accepted
- Date: 2026-08-11
- Decision owners: Platform Engineering

## Context

The test, non-production, and production EKS clusters use separate Argo CD
instances but share the same composition policy: one AppProject, one
cluster-wide ArkMQ operator Application, one shared ZooKeeper Application, and
one Workload Cell ApplicationSet. Copying those resources into every cluster
made revision propagation and policy changes easy to drift. Validation also
depended on copied filenames and fixed catalog counts instead of the manifests
Argo actually consumes.

## Decision

Keep the stable root paths under `gitops/argocd/bootstrap/<cluster>`, but make
each path a thin Kustomize adapter over one shared base. The adapter supplies
cluster identity and integration placeholders. The rendered output—not the
base's internal file layout—is the composition contract and validation seam.

The Terraform-owned root Application injects one selected Git revision into
the adapter's AppProject annotation. Kustomize replacements propagate it to
the operator, ZooKeeper, ApplicationSet generator, and generated Workload Cell
source. A temporary branch is therefore selected once per cluster during
Release Promotion; `main` remains valid for every cluster.

Each cluster retains one independent `workloadCells` catalog. Mechanical
Application, broker, group, Curator-path, ZooKeeper-endpoint, and redirect-URI
identities are derived by the shared ApplicationSet template. Existing names
remain unchanged. A separate baseline policy protects established Workload
Cells and their important traits while permitting additional valid, initially
disabled entries without validator changes.

The AppProject explicitly permits the platform namespace and uses
`artemis-*` for Workload Cell destinations. This is broader than enumerating
every current namespace, but it is bounded by a platform-owned prefix and lets
catalog growth avoid AppProject edits. Offline placeholders are accepted by
repository validation; deployable values must resolve to that prefix.

Workload Cell Profiles are Helm values files with a validated capability
contract. A Workload Cell selects exactly one Profile and may set only typed
features declared by it. Profiles cannot own Platform Release, HA,
coordination, durability, topology, or deletion-safety settings. Environment
values are restricted to cluster integrations, and validation rejects owner
collisions.

No custom catalog generator or expanded Application YAML is committed. Argo
uses its Git-files and list generators, while local validation renders the
same Kustomize adapter and checks externally observable composition behavior.

## Consequences

- Composition policy changes are implemented once and verified for all three
  stable root paths.
- A root revision cannot drift among child Git sources when the injection
  contract is followed.
- Adding a Workload Cell is a cluster-local catalog edit; new cells begin
  disabled and do not expand cluster-wide resources.
- The `artemis-*` destination grant relies on namespace naming governance as a
  security boundary and must not be widened to an unrestricted wildcard.
- Static rendering verifies desired composition and ordering intent only. It
  does not prove runtime readiness, HA safety, durability, or promotion
  acceptance.
