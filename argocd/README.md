# Argo CD composition

The examples create one platform operator Application and one shared
ZooKeeper Application per EKS cluster, followed by ten Artemis workload
Applications: two in `test`, four in `nonprod`, and four in `prod`.

Sync waves establish the dependency order:

1. `-20`: mirrored ArkMQ operator chart and CRDs;
2. `-10`: the three-member shared ZooKeeper ensemble; and
3. `0`: Artemis HA workloads.

All generated Applications enable automated reconciliation, pruning, and
self-healing. The operator Application reads a pinned `2.2.0` chart from the
placeholder ECR OCI repository and reads environment values through Argo CD's
multi-source `$values` reference. ECR repository credentials and cluster
registrations are configured outside this repository.

The workload ApplicationSet passes a unique Curator namespace for every HA
pair while pointing all pairs in a cluster at the shared ZooKeeper client
Service. The ZooKeeper Helm release name is explicitly identical to its
generated Application name, and each workload derives the corresponding
`<environment>-shared-zookeeper-zookeeper-client` endpoint. See
[the ZooKeeper topology ADR](../docs/adr-zookeeper-topology.md) for the
explicit dedicated-ensemble override.

Replace every `PLACEHOLDER_*` value before applying these examples. No
credentials, account identifiers, real cluster names, or real domains should
be committed.
