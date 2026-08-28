# Classic external-broker settings in the Artemis deployment

> **Deferred:** This design applies only to future external Workload Cells.
> Current internal Artemis clients use CIDR-based NetworkPolicy admission and
> do not authenticate to the broker.

The legacy external broker is not represented by copying its Chef JSON or JKS
paths into the container. The Artemis deployment separates non-secret desired
state in Git from externally materialized key, trust, and identity data.

| Classic setting | Artemis owner and representation |
| --- | --- |
| SSL transport on the external port | A dedicated entry under `acceptors` with `sslEnabled: true` and its own port and protocol set. |
| `needClientAuth=true` | `acceptors.<name>.needClientAuth: true`. The chart rejects this unless TLS and an SSL Secret are configured. |
| `/opt/keystore/activemq.jks` | The private key and server certificate are supplied through the acceptor's `sslSecret`; no filesystem path or private key is stored in Git. |
| `/opt/keystore/truststore_activemq.jks` and certificate aliases | The same operator SSL Secret supplies the client truststore. The security platform owns the approved CA bundle and its rotation. Alias names are inventory inputs, not broker configuration. |
| Users and passwords | An externally materialized `*-jaas-config` Secret mounted through `authentication.jaasSecretName`. Passwords remain in Vault or the approved Secret synchronization system. |
| Certificate DN users | `TextFileCertificateLoginModule` entries in the mounted JAAS Secret map an exact DN or reviewed DN regular expression to an Artemis user. |
| Classic groups | Artemis roles produced by the JAAS login modules. There is no separate Git-managed group object. |
| Queue/topic authorization entries | Typed rules under `authorization.rules`, rendered as `securityRoles` broker properties. |
| Queue list | Typed entries under `destinations`, rendered as `addressConfigurations` broker properties. |
| `DLQ.<source>` queues | The chart's catch-all address settings create and retain per-source DLQs. Do not duplicate them in `destinations` unless a migration exception requires a separately managed queue. |
| Classic remote JMX roles and connector ports | Map viewer/admin roles to `mops.#` `view`/`edit` grants and use the existing Hawtio/Jolokia path. Remote RMI/JMX ports are intentionally not exposed. |
| Classic JDBC message store and database locks | Intentionally replaced by the approved replicated file-journal HA design on pair-local persistent volumes. Database connection values are not migration inputs. |

## TLS and client-certificate authentication

Use a separate acceptor for the partner-facing path, even when it uses the same
protocol as an internal listener. This keeps the port, trust boundary, and
NetworkPolicy rules independently reviewable. A complete example is maintained
in
[`external-mtls-values.yaml`](../charts/artemis-ha/tests/fixtures/external-mtls-values.yaml).

The pinned operator consumes an SSL Secret referenced by `sslSecret`. For the
legacy JKS form, the external materialization process supplies these data keys:

- `broker.ks`: server private key and certificate chain;
- `client.ts`: approved client CA certificates;
- `keyStorePassword`: password for `broker.ks`; and
- `trustStorePassword`: password for `client.ts`.

The Secret name is safe to store in Git; the four values and files are not.
For cert-manager/trust-manager PEM material, keep `sslSecret` for the server
identity and set the optional `trustSecret` to the separately managed client CA
bundle.
The server certificate SANs must match the DNS name clients use. The truststore
must contain only currently approved client issuers. Migrating the legacy alias
list is therefore a security-team review and CA-bundle build, not a literal
copy of the old truststore.

`needClientAuth` proves that a client certificate chains to an approved issuer.
It does not by itself grant messaging permissions. The broker must also map the
certificate subject to an identity and roles. Configure
`authentication.jaasSecretName` with a Secret whose name ends in
`-jaas-config` and which contains `login.config` plus its referenced property
files. A certificate-based module follows this pattern:

```text
activemq {
  org.apache.activemq.artemis.spi.core.security.jaas.PropertiesLoginModule sufficient
    org.apache.activemq.jaas.properties.user="artemis-users.properties"
    org.apache.activemq.jaas.properties.role="artemis-roles.properties"
    baseDir="/home/jboss/amq-broker/etc";

  org.apache.activemq.artemis.spi.core.security.jaas.TextFileCertificateLoginModule sufficient
    reload=true
    org.apache.activemq.jaas.textfiledn.user="cert-users.properties"
    org.apache.activemq.jaas.textfiledn.role="cert-roles.properties";
};
```

The image's existing properties module must remain in the realm so the operator
and the chart's readiness probe retain their generated administrative identity.
In `cert-users.properties`, map a stable user name to the certificate's RFC 2253
subject DN. In `cert-roles.properties`, map each role to its user names. Broad DN
regular expressions such as an organization-wide wildcard require explicit
security approval; prefer an exact subject or the narrowest stable expression.

If a partner also needs username/password authentication, add a second
`PropertiesLoginModule` and its user/role files to the same externally
materialized JAAS Secret. Do not put passwords, password hashes, certificate
subjects, or rendered Secret data in Helm values.

## Groups and authorization

Translate the Classic authorization columns deliberately:

| Classic grant | Artemis operations |
| --- | --- |
| write | `send` |
| read | `consume` and, only when required, `browse` |
| admin | `createAddress`, `deleteAddress`, queue create/delete operations, and `manage` only where operationally required |

The new deployment pre-creates permanent destinations, so partner roles
normally need only `send`, `consume`, and perhaps `browse`. Creation, deletion,
and management stay with the administrative role. Do not automatically carry
forward a legacy `guests` grant.

Classic `>` is a multi-segment wildcard; the Artemis equivalent is `#`.
Artemis can scope a rule to an address or to a fully qualified queue name such
as `ADDRESS::QUEUE`. The chart escapes the `::` delimiter when rendering broker
properties. Preserve separate producer and consumer roles when the legacy read
and write group lists differ.

## Addresses and queues

For a JMS queue, create an `ANYCAST` address and a durable `ANYCAST` queue. For
a JMS topic, create a `MULTICAST` address; durable subscriptions are queues and
must be inventoried separately when they are broker-managed migration state.
The chart keeps permanent destination auto-creation disabled so a client typo
cannot create a new queue.

Before importing the screenshot inventory, produce a machine-readable catalog
with, for every destination:

- exact address and queue name;
- routing type and durability;
- producer, consumer, browser, and administrator roles;
- owning application and Workload Cell;
- DLQ/expiry behavior and migration disposition; and
- whether retained messages must be drained, replayed, archived, or abandoned.

Import only the destinations owned by a given HA pair into that pair's values.
Do not copy environment-prefixed wildcard entries into every pair without an
ownership review.

The values collections are maps keyed by review IDs, not lists. Helm therefore
deep-merges environment-wide entries with pair-specific entries from
`gitops/workloads/<environment>/<workloadCellName>/artemis-values.yaml`. The
keys are for Git review only; the nested `address`, queue `name`, and rule
`match` remain the broker-visible values.

## What remains outside this chart

The chart creates a readiness-gated `ClusterIP` Service for each enabled acceptor
and keeps the broker non-public by default. A partner connection still needs an
approved private TCP exposure path, DNS, firewall/security-group rules, and a
corresponding `networkPolicy` source. Those are platform-owned decisions and
must not be inferred from the presence of an external TLS acceptor.

Acceptance evidence must show: an approved certificate succeeds; an untrusted,
expired, or unmapped certificate fails; each role can perform only its allowed
operations; destination typos do not auto-create resources; and certificate,
JAAS, and password rotation complete without secret data entering Git, Argo CD
output, commands, or logs.
