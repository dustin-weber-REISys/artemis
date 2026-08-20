# Internal mTLS client onboarding

Use this guide to add certificate-authenticated internal application clients to
an Artemis Workload Cell. It records the current scope and the repository seam
for resuming the broader client-certificate design later.

> **Where to perform live operations:** This checkout is an offline/test copy.
> Request certificates, inspect Vault, materialize Kubernetes Secrets, and run
> `kubectl` only from the authorized work computer. Never put private keys,
> passwords, certificate subjects, real CA contents, account identifiers, or
> internal network ranges in this repository or captured command output.

## Decision record

As of 2026-08-20, the first client-certificate phase is internal-only.

- Use a dedicated internal mTLS acceptor rather than adding client
  authentication to the required `artemis` acceptor on port `61616`. That
  acceptor also carries operator-managed CORE peer traffic.
- Trust an approved enterprise client-certificate chain, preferably a narrowly
  scoped messaging-client intermediate rather than an organization-wide
  issuing CA.
- Keep TLS trust and Artemis authorization separate. A certificate that chains
  to an approved CA may complete the TLS handshake, but only a certificate DN
  mapped by the Artemis certificate login module receives an application role.
- Use one stable Artemis identity per application and environment. Individual
  pods may receive distinct short-lived certificates with the same mapped
  identity; do not create a credential per producer or consumer object.
- Defer the external-client listener, managed external truststore, external TCP
  exposure, and per-listener NetworkPolicy source model. See
  [Deferred external mTLS](#deferred-external-mtls).

## Trust model

The existing Vault SSH CA cannot issue certificates for Artemis TLS. OpenSSH
certificates and X.509 certificates are separate formats and Vault capabilities.
Use one of these approved X.509 paths:

1. **Enterprise-issued leaf certificates.** Request the broker server
   certificate and internal application client certificates through the
   existing enterprise PKI process. Vault or the approved synchronization
   system stores and delivers the resulting material.
2. **Enterprise-signed Vault intermediate.** If the security team permits
   delegated issuance, have Vault PKI generate an intermediate CSR, have the
   enterprise CA sign it, and let Vault issue short-lived application
   certificates from that intermediate. Keep the enterprise root outside
   Vault.

Do not create an independent self-signed Artemis CA when enterprise trust is
required. The broker trust bundle may contain the approved root and intermediate
chain, but a client is accepted only when all of the following hold:

- its presented chain terminates at an approved trust anchor;
- the chain is within its validity period and the leaf permits TLS client
  authentication;
- the configured revocation policy accepts it; and
- its normalized subject DN matches an approved Artemis application identity.

Trusting a root or intermediate trusts cryptographic descendants of that CA,
not certificates merely carrying a particular agency name. Prefer a dedicated
messaging-client intermediate. If a broad enterprise CA must be trusted, keep
the DN mapping exact or use the narrowest reviewed regular expression; never
grant `send` or `consume` to every certificate under the enterprise root.

HashiCorp documents the X.509 engine and recommended subordinate-CA pattern in
the [Vault PKI documentation](https://developer.hashicorp.com/vault/docs/secrets/pki)
and [PKI considerations](https://developer.hashicorp.com/vault/docs/secrets/pki/considerations).
Artemis documents DN allow-listing and role association in its
[certificate login module](https://artemis.apache.org/components/artemis/documentation/latest/security.html#certificateloginmodule).

## Required artifacts and owners

| Artifact | Purpose | Owner and repository representation |
| --- | --- | --- |
| Broker server certificate and private key | Proves the broker endpoint identity; SANs must cover the DNS name clients actually use | Security/platform materializes the operator SSL Secret; Git stores only `acceptors.<name>.sslSecret` |
| Internal client CA bundle | Validates incoming application certificate chains | Security/platform materializes the trust Secret, or the `client.ts` entry in the legacy operator SSL Secret; Git stores only `acceptors.<name>.trustSecret` when separate |
| Application leaf certificate and private key | Proves one internal application identity | Application platform obtains it from enterprise PKI or Vault and mounts it only into that client workload |
| JAAS configuration | Maps certificate DNs to stable users and users to roles | Identity/security materializes one `*-jaas-config` Secret; Git stores only `authentication.jaasSecretName` |
| Destination grants | Permits the mapped role to send, consume, or browse | Workload Cell values under `authorization.rules` |
| Network source allow-list | Limits which network sources can reach the listener before TLS | Workload Cell `clientSources` for Kubernetes selectors; environment `extraIngress` for approved CIDRs |

For the legacy JKS operator Secret shape and the required JAAS files, use the
[Classic external-security migration guide](../classic-external-security-migration.md#tls-and-client-certificate-authentication).
The same Secret mechanics apply to this internal-only listener even though the
trust source is different.

## 1. Confirm the approved enterprise chain

On the authorized work computer, ask the PKI/Vault owner to establish:

- whether Vault has a secrets-engine mount of type `pki`, separately from the
  existing `ssh` mount;
- the approved root and issuing intermediate for internal messaging clients;
- whether that issuer is restricted to application client certificates;
- the required subject or SAN convention for stable application identity;
- the permitted client and server extended key usages;
- certificate lifetime, renewal overlap, CRL or OCSP location, and fail-open or
  fail-closed revocation behavior; and
- whether the operator consumes a JKS/PKCS12 SSL Secret or separate PEM server
  and trust Secrets in the installed version.

These Vault inventory commands are read-only. Do not paste their output into
Git, tickets, or chat without sanitizing internal mount and role names:

```sh
vault secrets list -detailed
vault list PKI_MOUNT/issuers
vault list PKI_MOUNT/roles
```

If no `pki` mount exists, the SSH CA is not a substitute. Use the approved
enterprise leaf-request process until the security team authorizes a Vault PKI
intermediate and issuance roles.

## 2. Materialize broker identity, trust, and JAAS Secrets

The Secret synchronization mechanism is external to this chart. It must create
the exact operator-compatible Secret objects in the Workload Cell namespace
before the `ActiveMQArtemis` resource references them.

For a separate PEM trust bundle, use these logical objects:

- `INTERNAL_BROKER_TLS_SECRET`: server private key and full server certificate
  chain;
- `INTERNAL_CLIENT_CA_SECRET`: approved internal client root/intermediate
  bundle; and
- `INTERNAL_CLIENTS_JAAS_CONFIG`: `login.config`, certificate user mappings,
  and certificate role mappings. Its Kubernetes Secret name must end in
  `-jaas-config`.

The JAAS configuration must preserve the image/operator-generated
`PropertiesLoginModule`, because the operator and readiness probe retain their
administrative credential. Add a `TextFileCertificateLoginModule` realm for
the internal listener. Configure `reload=true` and `normalise=true` after
confirming both options against the pinned runtime image.

Map a stable application name to the normalized RFC 2253 subject DN, then map
that user to a least-privilege role. Renewal with the same identity should not
require a Git change. Adding a new application identity or changing its role
does require a reviewed JAAS Secret update and authorization test.

The chart's existing `vault.enabled` annotation is not this integration. It
can inject a file, but the repository does not yet prove that the operator uses
that file as an effective SSL or JAAS Secret. Use the platform's approved
Secret-sync bridge until that gap is implemented and tested.

## 3. Add the internal mTLS acceptor

Put the pair-owned listener and JAAS Secret reference in:

```text
gitops/workloads/<environment>/<workloadCellName>/artemis-values.yaml
```

The following is a shape example only. Port `61618` and every placeholder name
must be replaced with reviewed values. Add one listener per required protocol;
do not enable protocols that have no inventoried clients.

```yaml
acceptors:
  internal-openwire:
    enabled: true
    port: 61618
    protocols: OPENWIRE
    connectionsAllowed: 10000
    bindToAllInterfaces: true
    supportAdvisory: true
    suppressInternalManagementObjects: false
    sslEnabled: true
    needClientAuth: true
    sslSecret: PLACEHOLDER_INTERNAL_BROKER_TLS_SECRET
    trustSecret: PLACEHOLDER_INTERNAL_CLIENT_CA_SECRET
    extraParams:
      securityDomain: internal-certificates

authentication:
  jaasSecretName: PLACEHOLDER_INTERNAL_CLIENTS_JAAS_CONFIG-jaas-config
```

The generic acceptor template already creates the broker acceptor and an
active-only `ClusterIP` Service. It also rejects a missing SSL Secret, client
authentication without TLS, a duplicate port, or removal of CORE from the
peer acceptor.

Do not change the existing `artemis` listener on `61616` to require client
certificates. Retain it for broker peer traffic and manage any legacy client
migration separately.

## 4. Map certificate identities to destination permissions

Trusting the CA is not permission to use every queue. Add least-privilege rules
to the same Workload Cell values file:

```yaml
authorization:
  rules:
    example-request:
      match: EXAMPLE.REQUEST
      permissions:
        send:
          - example-producer
        consume:
          - example-consumer
        browse:
          - example-consumer
```

The role names must match the externally materialized JAAS role mappings.
Grant application roles only `send`, `consume`, and `browse` as required.
Address/queue creation, deletion, and broker management remain administrative.

## 5. Allow internal network sources

There are two distinct repository seams.

### Kubernetes namespace and pod selectors

For clients running inside the EKS cluster, add pair-owned selectors to the
same Workload Cell file:

```yaml
networkPolicy:
  clientSources:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: PLACEHOLDER_CLIENT_NAMESPACE
      podSelector:
        matchLabels:
          app.kubernetes.io/name: PLACEHOLDER_CLIENT_APPLICATION
```

This is the preferred in-cluster control because it follows workload identity
instead of allocating access to an entire network.

### Approved internal CIDR ranges

For internal clients that originate outside the cluster, update the matching
environment overlay:

```text
gitops/environments/<environment>/artemis-values.yaml
```

Add an `ipBlock` under `networkPolicy.extraIngress` and restrict it to the
internal mTLS port. This documentation-range example must never be deployed:

```yaml
networkPolicy:
  extraIngress:
    - from:
        - ipBlock:
            cidr: 192.0.2.0/24 # documentation only; replace in the authorized copy
      ports:
        - port: 61618
          protocol: TCP
```

`extraIngress` in an environment overlay is composed into every Artemis
Workload Cell in that environment. Use it only for CIDRs genuinely approved
for all those brokers. Do not put internal CIDRs in the chart defaults.

The repository does not currently allow a pair-specific `extraIngress` entry
in a Workload Cell file, and `clientSources` accepts only namespace/pod
selectors. If different HA pairs require different CIDR ranges, stop and add a
typed pair-owned CIDR interface plus focused NetworkPolicy tests rather than
placing the union of all ranges in the environment overlay.

Before relying on an `ipBlock`, the platform team must verify the source IP
observed by the broker pods through the selected private TCP exposure path.
Some Kubernetes and load-balancer paths may preserve, translate, or replace
the original source address. Permit the smallest observed approved range.

## 6. Validate before promotion

Run repository validation locally:

```sh
make validate-charts
make validate-topology
```

`validate-topology` requires the generated effective topology catalogs. If they
are absent or stale, regenerate them through the repository's topology workflow
before treating validation as complete; a passing chart render is not a
substitute for composed Workload Cell validation.

Review the rendered `ActiveMQArtemis`, listener Service, and NetworkPolicy. No
rendered artifact may contain private keys, passwords, certificate subjects,
or certificate contents.

In the test EKS environment, collect evidence for all of these cases:

1. An approved, mapped certificate connects and performs only its permitted
   send or consume operations.
2. A certificate from the approved CA with an unmapped DN is rejected by
   Artemis authentication.
3. A certificate from an untrusted issuer fails the TLS handshake.
4. An expired certificate fails; a revoked certificate fails when the approved
   CRL/OCSP policy requires it.
5. A client outside the approved selector or CIDR cannot reach the listener.
6. Certificate and CA rotation preserve service with an intentional overlap
   window and do not expose secret material in manifests or logs.
7. Broker replication and readiness remain healthy, proving that the new
   listener did not alter the `61616` CORE peer path.

The chart's current tests prove rendering only. Client-certificate runtime
compatibility remains pending until this evidence is recorded against the
pinned operator and broker images.

## Deferred external mTLS

External client mTLS is deliberately out of the first phase. Resume it as a
separate trust boundary with:

- a separate acceptor, Service, port, `securityDomain`, and external trust
  bundle;
- the managed external-client truststore or reviewed external issuing CAs;
- an approved private TCP exposure path and DNS name;
- per-listener NetworkPolicy source selection so internal and external sources
  are not each allowed to reach every client port;
- external client identity and authorization reconciliation; and
- positive, unmapped, untrusted, expired, revoked, rotation, and failover tests.

The reusable chart surface and a sanitized external fixture already exist in
[`external-mtls-values.yaml`](../../charts/artemis-ha/tests/fixtures/external-mtls-values.yaml).
The missing work is Secret materialization, exposure, per-listener network
source scoping, and runtime acceptance—not basic acceptor rendering.
