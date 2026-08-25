# Local Artemis development

[`compose.yaml`](compose.yaml) runs one durable standalone Artemis broker for
application wiring and validation-client smoke tests. It is independent of the
EKS design: there is no operator, ZooKeeper, second broker, replication,
failover, Vault, Keycloak, ingress, or production authorization.

Use the canonical local commands in the root
[`README`](../README.md#local-development). Docker Engine with Compose v2 is
required. The Compose file is authoritative for the image, published ports,
health check, volume, and smoke workflow; [`.env.example`](.env.example) is
authoritative for local credentials and supported host-port overrides.

## Persistence and reset

Normal stop/start preserves the named volume. The first start creates the broker
instance in that volume, so changing creation-time credentials or Jolokia
settings does not reconfigure an existing instance. After updating from a
version that did not enable relaxed local Jolokia access, run the destructive
`make local-reset` target once before `make local-up`. The reset removes this
Compose project's broker volume and all retained queues and messages.

The local Makefile keeps the Compose project name `artemis`, preserving the
named-volume identity used before this directory split.

The volume initializer only grants the image runtime user access to a new
volume. It does not run another broker. The startup wrapper regenerates broker
configuration only when the broker executable is absent, preserving normal
restart behavior.

## Security limitation

The upstream standalone image's launcher creates the local instance with
anonymous access enabled even when explicit client credentials are supplied.
The values in `.env.example` are the supported local client and console
credentials, but this stack does not demonstrate strict authentication. Never
reuse them outside local development.

The local broker is created with `--relax-jolokia` so the Hawtio console opened
at `http://localhost:8161/console` can display its Artemis management views,
including connections, addresses, queues, and messages. This relaxation is for
the standalone localhost workflow only and is not a production security model.

The relevant upstream behavior is documented in the
[ArkMQ basic image tutorial](https://arkmq.org/docs/tutorials/deploybasicimage/)
and [standalone launch script](https://github.com/arkmq-org/arkmq-org-broker-image/blob/main/modules/apache-artemis-install/added/launch.sh).

## Smoke test and application connections

The smoke profile builds the Java client owned by
[`performance`](../performance) in a temporary local image and sends uniquely
identified persistent traffic through the protocols defined in `compose.yaml`.
Host Java and Maven are not required.

Host applications connect through the published localhost ports. Applications
added to the Compose project connect to the `broker` service and its container
ports. Use the current Compose configuration rather than copying endpoints from
this guide.

## What this proves

The stack demonstrates that the pinned local image starts with durable local
state and that the validation client can exchange messages through the
configured smoke protocols. It is useful for application wiring, message
format checks, and persistence across normal restarts.

It does not prove EKS placement, EBS behavior, operator reconciliation,
ZooKeeper locking, synchronous replication, failover, NetworkPolicy, Vault,
Keycloak authorization, ingress TLS, monitoring, backup, or production
performance. Use chart validation and approved EKS scenarios for those claims.
