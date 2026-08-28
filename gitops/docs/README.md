# GitOps documentation

This index distinguishes current sources of truth from procedures, proposals,
and research. Start with the
[repository change guide](../../docs/repository-guide.md) when deciding where a
configuration change belongs.

## Architecture and sources of truth

- [Implementation specification](implementation-spec.md) — current end-to-end
  design and ownership baseline.
- [Cluster composition ADR](adr-cluster-composition.md) — accepted Argo CD and
  Kustomize composition.
- [Operator HA ADR](adr-operator-ha.md) — accepted ArkMQ-managed active/passive
  design and remaining runtime acceptance.
- [Workload Cell topology ADR](adr-workload-cell-topology.md) — accepted cell,
  Profile, sizing, and messaging-policy boundaries.
- [Shared private NLB ADR](adr-shared-private-nlb.md) — accepted private TCP
  exposure design, listener-allocation boundary, and implementation gates.
- [ZooKeeper topology ADR](adr-zookeeper-topology.md) — accepted shared-quorum
  design and rollout constraints.
- [Production workload baseline](production-workload-baseline.md) — working
  evidence baseline, not a capacity commitment.

The deployed values and manifests are authoritative for implementation detail:
`gitops/releases/current.yaml`, `gitops/argocd/`, `gitops/charts/`, and
`gitops/kustomize/`. If prose conflicts with rendered artifacts, stop and fix
the conflict rather than choosing whichever version is convenient.

## Integration and migration guides

- [Environment import and deployment](environment-import-walkthrough.md) —
  current integration workflow and promotion gates.
- [Chef ActiveMQ import](chef-activemq-import.md) — supported, review-only
  translation of legacy Chef data.
- [Classic environment crosscheck](classic-environment-configuration-crosscheck.md)
  — disposition of photographed or manually inventoried Classic settings.
- [Classic external-security migration](classic-external-security-migration.md)
  — mapping legacy TLS, identity, authorization, and destinations.
- [Helm chart mirroring to ECR](helm-ecr-mirroring.md) — deferred design and
  pipeline assets; it is not the current Argo chart source.

## Operations runbooks

- [Install verification](runbooks/install-verification.md)
- [Incident triage](runbooks/incident-triage.md)
- [Hawtio access diagnosis](runbooks/hawtio-access-diagnosis.md)
- [Broker reconciliation debugging](runbooks/broker-reconciliation-debugging.md)
- [Failover and failback](runbooks/failover-failback.md)
- [Upgrade and rollback](runbooks/upgrade-rollback.md)
- [Backup and restore](runbooks/backup-restore.md)
- [Internal CIDR onboarding](runbooks/internal-cidr-onboarding.md)
- [Protocol acceptor inventory and retirement](runbooks/protocol-acceptor-inventory.md)
- [Workload Cell retirement](runbooks/workload-cell-retirement.md)
- [ActiveMQ Classic 6.2.6 compatibility](runbooks/classic-6.2.6-compatibility.md)

Commands that inspect or mutate a live cluster are for the authorized work
computer only. From this offline checkout, use the runbooks to prepare exact
commands and validate repository artifacts.

## Proposals

- [External client mTLS modernization](external-client-mtls-modernization.html)
  — proposed design, version 0.1; not implemented or authoritative.

When a proposal is accepted, record the decision in an ADR and update the
implementation and runbooks. Remove the proposal if it no longer adds useful
decision history.

## Research and decision history

The `research/` directory and `research-*.md` files contain dated decision
inputs. They are non-authoritative and may age as upstream projects change:

- [ArkMQ Helm and Kustomize research](research/arkmq-operator-helm-kustomize.md)
- [ZooKeeper chart options](research-zookeeper-chart-options.md)
- [Strimzi, Kafka, and ZooKeeper](research-kafka-strimzi-zookeeper.md)

Current implementation choices belong in the ADRs and module READMEs, not in a
research note. Verify upstream facts again before using research in a new
decision.

## Documentation maintenance

- Put stable architecture decisions in ADRs, executable procedures in
  `runbooks/`, and temporary investigation in `research/`.
- Link every new guide from this index or the closest area README.
- Delete completed one-time migration checklists once their durable controls
  are represented in code, validation, and current guides.
- Update commands when Make targets or scripts change; do not preserve copied
  command sequences as a second source of truth.
- Run `make validate-docs` after moving, renaming, or editing documentation.
