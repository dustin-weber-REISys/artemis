# Argo CD composition

The ApplicationSets separate platform dependencies from Artemis workloads so
the operator and coordination service can become healthy before broker custom
resources are reconciled. Their generators, destinations, source revisions,
release names, sync waves, and Helm parameters are authoritative in
[`applications`](applications).

Argo CD cluster registration, Git credentials, and private OCI credentials are
owned by the GitOps platform outside this repository. Replace all placeholders
before applying the project or ApplicationSets, and bootstrap them in the
controlled sequence in the
[`environment import guide`](../docs/environment-import-walkthrough.md#bootstrap-sequence).

Workloads normally share the per-cluster ZooKeeper client service while using
pair-unique coordination identities. The rationale and the separately approved
dedicated-ensemble option are in the
[`ZooKeeper topology ADR`](../docs/adr-zookeeper-topology.md).
