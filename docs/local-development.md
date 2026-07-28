# Local Artemis development

This repository includes a small Docker Compose topology for application and
microservice development. It runs one durable, standalone Apache ActiveMQ
Artemis broker using the ArkMQ broker image at Artemis `2.53.0`:

```text
host applications  ── published ports ──>  broker
Compose smoke test ── broker:61616/5672 ─>  named volume: /home/jboss/broker
```

The local broker is intentionally independent from the EKS deployment model.
It does not run the operator, ZooKeeper, Keycloak, Vault, a second broker,
replication, or failover.

## Start and stop

Docker Desktop or another Docker Engine with Compose v2 is required. Defaults
are usable without creating an environment file:

```sh
make local-up
make local-status
make local-logs
make local-down
```

`local-up` waits for the broker health check before returning. `local-down`
stops and removes the Compose container but keeps the named volume. To remove
the local broker instance, journal, queues, and messages as well:

```sh
make local-reset
```

The reset target is intentionally destructive, but is limited to this
Compose project's named volume. Copy `.env.example` to `.env` only when you
want to override the defaults; `.env` is ignored by Git.

## Endpoints and credentials

All published endpoints bind to `localhost` by default:

| Protocol or UI | Host endpoint | Container endpoint |
| --- | --- | --- |
| OpenWire | `tcp://localhost:61616` | `61616` |
| AMQP 1.0 | `amqp://localhost:5672` | `5672` |
| STOMP | `localhost:61613` | `61613` |
| MQTT | `localhost:1883` | `1883` |
| Hawtio console | [http://localhost:8161/console](http://localhost:8161/console) | `8161` |

The default local-only credentials are `localdev` / `localdev`. They are
passed to the broker as `AMQ_USER` and `AMQ_PASSWORD`; applications should use
those values when they connect. Do not reuse them outside this local stack.

The standalone ArkMQ launch script creates the broker instance in
`/home/jboss/broker`, and a first run stores the generated security and broker
configuration in the named volume. Changing `ARTEMIS_USER` or
`ARTEMIS_PASSWORD` in `.env` therefore requires `make local-reset` before the
new credentials take effect. Compose invokes that launcher through a small
startup wrapper: because an empty volume mounted at `/home/jboss/broker`
already creates the mount directory, the wrapper sets `AMQ_RESET_CONFIG=true`
only when `broker/bin/artemis` is absent. Existing broker configuration is
therefore not regenerated on normal restarts. A one-shot root-owned Compose
initializer grants the image's runtime UID 185 access to the new named volume;
it does not run a second broker.

The standalone image does not expose the Kubernetes image's `AMQ_REQUIRE_LOGIN`
or `AMQ_DATA_DIR` controls in its launcher. The requested protocol listeners
come from the standard Artemis `create` acceptors, while Compose publishes
their local ports; this file does not rely on an unsupported transport or data
directory variable.

The standalone image's documented launch behavior always includes
`--allow-anonymous` when it creates the instance, even when `AMQ_USER` and
`AMQ_PASSWORD` are supplied. The credentials above are therefore the
supported, explicit local client and console credentials, but this stack does
not claim strict authentication enforcement. `AMQ_REQUIRE_LOGIN` is exposed
by the Kubernetes image metadata, not by the standalone image's launcher, so
it is deliberately not set here. The health check uses the credentialed
Artemis CLI `check node` command over OpenWire and verifies that the broker's
management view reports the node as started.

This behavior is documented by [ArkMQ's basic broker image tutorial](https://arkmq.org/docs/tutorials/deploybasicimage/)
and the standalone image's [launch script](https://github.com/arkmq-org/arkmq-org-broker-image/blob/main/modules/apache-artemis-install/added/launch.sh).

## Smoke test

The repeatable smoke test builds the existing Java validation client inside a
temporary, local-only Compose image, so host Maven and Java are not required:

```sh
make local-smoke
```

It waits for broker readiness, then sends and consumes ten persistent messages
over OpenWire and ten over AMQP 1.0. Each run uses unique destinations and ID
prefixes so retained data from earlier runs cannot be mistaken for new test
messages. The production validation-client image remains separately
digest-pinned; `Dockerfile.local` is only for this developer smoke path.

## Connecting applications

An application running on the host uses `localhost` and the published host
port, for example:

```text
OpenWire: tcp://localhost:61616
AMQP:     amqp://localhost:5672
User:     localdev
Password: localdev
```

An application added as another Compose service uses the broker service name
and the container port, not `localhost`:

```text
OpenWire: tcp://broker:61616
AMQP:     amqp://broker:5672
```

The service must join this Compose project's default network. Published host
ports are not needed for service-to-service traffic.

## Apple Silicon

No `platform` override is set. The pinned broker reference resolves to a
Linux `amd64` or `arm64` image on Docker Desktop, so Apple Silicon can use the
same Compose file. The local smoke-test build also uses multi-architecture
Maven and Temurin images. If another local process already owns one of the
default ports, set the corresponding `ARTEMIS_*_PORT` variable in `.env`.

## Scope and limitations

This stack proves that the pinned Artemis runtime can start with a durable
local instance and that the repository's validation client can send and
receive over OpenWire and AMQP. It is useful for local application wiring,
message format checks, persistence across a normal stop/start, and basic
developer workflows.

It does not prove EKS scheduling, EBS behavior, operator reconciliation,
ZooKeeper locking, synchronous replication, active/passive failover,
network-policy behavior, Vault injection, Keycloak authorization, ingress TLS,
Prometheus integration, or production performance. Use the Helm and EKS
scenario validation for those claims.
