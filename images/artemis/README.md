# Artemis image policy

The chart uses the upstream ArkMQ Kubernetes broker and init images for
Artemis `2.53.0`; it does not build a derived image. The default values retain
the upstream tags for traceability and pin the exact Quay manifest digests.
Deployment overlays should replace only `images.*.repository` when mirroring
to a private registry and must retain, review, and re-record the digest after
the mirror operation.

The HA chart relies on the upstream Artemis distribution for the ZooKeeper
Curator lock-manager class and on the operator-compatible launch scripts. A
runtime image acceptance test must verify that the selected mirrored image
contains `org.apache.activemq.artemis.lockmanager.zookeeper.CuratorDistributedLockManager`.
If it does not, add a thin, non-root derived image from the exact pinned
upstream image, include the Apache/ArkMQ license and source attribution, and
update the chart digest and ADR before promotion.

No credentials, environment names, domains, or registry credentials belong in
this directory.
