# Classic environment configuration crosscheck

This crosscheck records the configuration shapes visible in the supplied
environment screenshots without copying internal identities, hosts, URLs,
certificate subjects, aliases, or token-bearing browser data into Git. It
answers whether the repository has a configuration interface for each shape;
it does not claim that truncated photographs are an exact destination export or
that compatibility has passed at runtime.

| Observed Classic shape | Artemis representation | Repository coverage | Remaining gate |
| --- | --- | --- | --- |
| OpenWire on `61616` plus broker peer traffic | Required `artemis` acceptor with `CORE,OPENWIRE` | Render validation prevents removing CORE, moving the peer port, or duplicating an enabled port | Existing client reconnect/failover test |
| AMQP, STOMP, MQTT, and HTTP/WebSocket listeners | Independently keyed acceptors with typed port, protocol, and connection limit | Default chart listeners and port/Service/NetworkPolicy coherence tests | Remove any unused protocol only after live inventory |
| TLS OpenWire and TLS STOMP listeners with client authentication | Additional acceptors with `sslEnabled`, `needClientAuth`, `sslSecret`, optional `trustSecret`, and per-acceptor `securityDomain` in `extraParams` | Sanitized external fixture renders both listener forms | Approved exposure path, certificate-negative tests, and rotation |
| Classic NIO/SSL transport labels and buffer/inactivity tuning | Artemis Netty acceptors; protocol-specific knobs use `extraParams` | Typed listener core plus constrained string parameter map | Translate each numeric field from the source JSON by meaning, then load-test; do not positionally copy the photographed arrays |
| ActiveMQ advisory topics and broad Classic wildcard grants | Explicit `supportAdvisory`; `ActiveMQ.Advisory.#` authorization rule; Classic `>` becomes Artemis `#` | Sanitized fixture and OpenWire-only advisory validation | Advisory-consumer compatibility and performance evidence |
| Large queue catalog, DLQ-prefixed queues, and topic authorization | Keyed `destinations` maps with ANYCAST queues or MULTICAST addresses; automatic per-source DLQ policy | Duplicate address/queue and routing-type validation | Machine-readable exact export, ownership assignment, and backlog disposition |
| Separate read, write, and admin group columns | `consume`/`browse`, `send`, and narrowly selected create/delete/manage permissions | Keyed `authorization.rules` maps and protected broker-property namespace | Least-privilege positive and negative tests; no automatic carry-forward of guest access |
| Password users, groups, encrypted passwords, and certificate-DN users | Externally materialized `*-jaas-config` Secret containing JAAS and referenced properties | Secret-name-only chart interface and mounted operator configuration | Identity owner supplies values and tests reload/rotation; no secret material in Git |
| Server keystore, truststore, and certificate alias inventory | Operator SSL Secret, or server SSL Secret plus separate trust bundle | TLS Secret references are rendered; paths and contents are excluded | Security team rebuilds the approved chain and validates SANs, expiry, revocation, and rotation |
| Keycloak/Hawtio realm, client, and redirect settings | Environment Keycloak baseline plus cell-derived redirect URI | Existing OIDC ConfigMap, ingress, and topology validation | Browser login and direct Jolokia authorization tests |
| Read-only and read/write JMX roles | `mops.#` `view` and `edit` permissions with operator management RBAC | Sanitized fixture renders both role levels | Verify principal-class mapping and that no competing `management.xml` interceptor is active |
| Remote JMX/RMI ports | No direct replacement; use Hawtio/Jolokia and metrics Services | NetworkPolicy and Services do not expose legacy RMI/JMX | Confirm no automation depends on remote JMX before retirement |
| Jetty bind/listen settings | Operator-owned embedded console on fixed `8161`, active-only Service, and managed ingress | Fixed chart helper keeps probes, Service, ingress, and policy coherent | Shared ALB, DNS, TLS, and health evidence |
| PostgreSQL broker store, pool sizing, and database lock timing | Replicated Artemis file journal on two retained persistent volumes with ZooKeeper activation lock | Protected HA and durability properties reject a JDBC override | Migration performance, failover, backup/restore, and acknowledged-message evidence |

## Configuration layering

The ApplicationSet loads values in this order:

1. an approved reusable Profile;
2. the cluster environment baseline; and
3. the required Workload Cell file under `gitops/workloads`.

Acceptors, destinations, and authorization rules are keyed maps, so later files
can add or refine named entries without replacing unrelated entries. The
environment validator permits shared messaging entries only in the environment
layer. The workload validator permits only pair-owned listener, identity Secret
reference, destination, authorization, and client-source paths. Release, HA,
ZooKeeper, storage, topology, and durability remain outside that seam.

## Exact-import limitation

The screenshots demonstrate configuration categories but crop or blur parts of
the destination and authorization lists. Do not transcribe them as the source
of truth. Export the original JSON on the work computer and use the
[`import-chef-activemq.py`](../scripts/import-chef-activemq.py) review workflow
documented in the [Chef import guide](chef-activemq-import.md). The importer
creates typed candidates plus a disposition report; it cannot determine whether
a declared listener, destination, or role is still live. Apply current-use
evidence and a per-environment cleanup policy before copying approved entries
into a Workload Cell. Treat any credential or token visible in a browser address
bar as exposed and rotate it through its owning system.
