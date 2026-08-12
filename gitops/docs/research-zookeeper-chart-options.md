# ZooKeeper chart options

Research date: 2026-08-11

## Summary

Artemis should keep the repository-owned Kustomize deployment. There is no
Apache ZooKeeper project Helm chart, the most complete standalone chart now has
a commercial image-distribution constraint, and the actively maintained
operator alternative would add several controllers and CRDs.

| Option | Maintenance and license | Relevant capabilities | Main concern |
| --- | --- | --- | --- |
| [Bitnami ZooKeeper chart](https://github.com/bitnami/charts/tree/main/bitnami/zookeeper) | Chart source remains maintained under Apache-2.0. | StatefulSet and PVCs; configurable replica count; PDB; anti-affinity and topology spread; NetworkPolicy; ServiceMonitor and PrometheusRule; image digest, registry, and pull-secret settings; client/quorum SASL and TLS. | Production-ready images and updated packaged charts moved to Bitnami Secure Images. Public OCI charts are frozen and generally require image overrides. |
| [Apache ZooKeeper](https://github.com/apache/zookeeper) | ZooKeeper itself is active and Apache-2.0; 3.9.5 is current and 3.8.6 is stable. | Signed source and binary releases and Maven artifacts. | The Apache ZooKeeper project does not publish a standalone Helm chart. |
| [Pravega ZooKeeper Operator](https://github.com/pravega/zookeeper-operator) | Apache-2.0, explicitly alpha. Latest published release is 0.2.15 from 2023. | Three replicas by default; StatefulSet and persistent storage; PDB; affinity and topology spread; private image repository and pull-secret settings. | Published artifacts are stale, the release used ZooKeeper 3.7.1, and first-class NetworkPolicy, Prometheus Operator resources, image-digest pinning, and TLS/authentication management are absent from the published chart interface. |
| [Stackable ZooKeeper Operator](https://github.com/stackabletech/zookeeper-operator) | Actively maintained; release 26.7.0 supports ZooKeeper 3.9.5. Source is OSL-3.0. | Three-node HA; StatefulSets and PVCs; PDB; pod spreading; built-in Prometheus metrics; public, mirrored, private, and custom images; quorum TLS by default and client TLS authentication. | Requires the Commons, Secret, Listener, and ZooKeeper operators. It is an operator-platform adoption, not a simpler chart replacement, and OSL-3.0 may require legal review. |
| [Hypertrace ZooKeeper chart](https://github.com/hypertrace/zookeeper) | Apache-2.0; latest release shown is 0.2.10 from 2024-11-13. | Standalone StatefulSet/PVC chart with PDB, anti-affinity, JMX exporter, ServiceMonitor, and PrometheusRule. | Small and inactive-looking project; no evidence in its current interface of ZooKeeper 3.9.5, NetworkPolicy, digest pinning, or managed TLS/authentication. |

## Source notes

### Bitnami

The chart has the broadest production feature set of the standalone choices.
Its documented values include PVC persistence, PDBs, placement controls,
NetworkPolicy, Prometheus Operator resources, digest/private-registry support,
and client and quorum security configuration:

- [Bitnami ZooKeeper chart source and values documentation](https://github.com/bitnami/charts/tree/main/bitnami/zookeeper)
- [Bitnami charts license](https://github.com/bitnami/charts)

The distribution model is the blocker. Bitnami states that, after August 2025,
existing public OCI charts remain available but no longer receive updates and
will not work out of the box unless their images are overridden. Versioned
legacy images receive no updates, while production-ready images and charts are
part of the commercial BSI offering:

- [Bitnami catalog transition notice](https://github.com/bitnami/containers/issues/83267)
- [Bitnami ZooKeeper container source](https://github.com/bitnami/containers/tree/main/bitnami/zookeeper)

The chart documents PVC creation but not a first-class StatefulSet
`persistentVolumeClaimRetentionPolicy` setting. PVC survival therefore depends
on normal Kubernetes retention behavior rather than an explicit chart value.

### Apache official status

Apache publishes signed source and binary archives and Maven artifacts, but its
release inventory and repository do not contain a ZooKeeper Helm chart. The
absence of an official chart is an inference from those official inventories,
not an Apache deprecation statement.

- [Apache ZooKeeper releases](https://zookeeper.apache.org/releases/)
- [Apache ZooKeeper source and packaging](https://github.com/apache/zookeeper)
- [Apache ZooKeeper security advisories](https://zookeeper.apache.org/security/)

Application-specific Apache projects such as Pulsar may include ZooKeeper
templates, but those templates are coupled to their parent application and are
not an Apache ZooKeeper base chart.

### Pravega

Pravega's published chart is a thin wrapper around its operator. The repository
labels the project alpha, and the latest release page remains 0.2.15. That
release upgraded its bundled ZooKeeper only to 3.7.1; Apache declared the 3.7
line end-of-life in 2024.

- [Pravega operator release 0.2.15](https://github.com/pravega/zookeeper-operator/releases/tag/v0.2.15)
- [Pravega cluster chart](https://github.com/pravega/zookeeper-operator/tree/master/charts/zookeeper)
- [Published Pravega operator images](https://hub.docker.com/r/pravega/zookeeper-operator/tags)
- [Apache ZooKeeper release news and 3.7 EOL](https://zookeeper.apache.org/news/)

The current source README mentions a newer ZooKeeper version, but the published
chart and image remain tagged 0.2.15. Unreleased source changes should not be
treated as maintained deployable artifacts.

### Stackable

Stackable is the strongest actively maintained open-source operator candidate.
Its 26.7 documentation supports ZooKeeper 3.9.5, persistent storage, controlled
disruptions, pod spreading, metrics, custom registries, and TLS. Its installation
requires four operators, however, and custom images must conform to the file
layout expected by the Stackable release line.

- [Stackable ZooKeeper operator overview and supported versions](https://docs.stackable.tech/home/stable/zookeeper/)
- [Stackable operator installation](https://docs.stackable.tech/home/stable/zookeeper/getting_started/installation/)
- [Storage and resource configuration](https://docs.stackable.tech/home/stable/zookeeper/usage_guide/resource_configuration/)
- [Allowed pod disruptions](https://docs.stackable.tech/home/stable/zookeeper/usage_guide/operations/pod-disruptions/)
- [Pod placement](https://docs.stackable.tech/home/stable/zookeeper/usage_guide/operations/pod-placement/)
- [Monitoring](https://docs.stackable.tech/home/stable/zookeeper/usage_guide/monitoring/)
- [Authentication](https://docs.stackable.tech/home/stable/zookeeper/usage_guide/authentication/)
- [Product image selection](https://docs.stackable.tech/home/stable/concepts/product-image-selection/)

The reviewed documentation promises a Prometheus endpoint but does not establish
that the operator creates ServiceMonitor or PrometheusRule resources. It also
does not document image digest pinning as a first-class field.

## Recommendation

Keep the Kustomize base and overlays as the production implementation. This
keeps resource identity, PVC behavior, image provenance, and Argo CD rendering
under repository control without introducing a paid artifact dependency or an
operator control plane.

Use the Bitnami chart source as a reference for optional PDB, NetworkPolicy,
monitoring, TLS, and authentication patterns. Evaluate Stackable separately
only if Artemis develops a real need for operator-managed day-two lifecycle
behavior that justifies its additional controllers, CRDs, image conventions,
and license review. Do not adopt the Pravega operator for new deployments.
