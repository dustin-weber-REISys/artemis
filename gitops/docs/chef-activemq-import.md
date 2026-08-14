# Importing Chef ActiveMQ environment JSON

The Chef importer converts the legacy configuration shape into review-only
Artemis workload values candidates. It does not edit a Workload Cell, deploy a
broker, contact Chef, or access a Kubernetes cluster.

Run it once for each Chef environment JSON export from a secure workstation:

```bash
./gitops/scripts/import-chef-activemq.py \
  --input /secure/export/AWSPP.json \
  --environment prod \
  --output-dir /tmp/artemis-chef-import/AWSPP \
  --ssl-secret-name approved-broker-tls \
  --trust-secret-name approved-client-ca \
  --jaas-secret-name approved-clients-jaas-config
```

The importer finds `activemq` beneath a Chef `default_attributes` or
`override_attributes` wrapper, or at any other unambiguous JSON path. Use
`--activemq-path override_attributes.activemq` when more than one object is
present. By default every key under `activemq.brokers` receives its own
`*.artemis-values.candidate.yaml`; repeat `--broker NAME` to select only named
brokers.

The output directory must be new or empty unless `--force` is explicit. It
contains:

- one candidate values file per selected legacy broker;
- `migration-report.json`, with item-level source paths and dispositions; and
- `migration-review.md`, with the review summary.

Candidate files are deliberately marked `DO NOT APPLY DIRECTLY`. Copy only
approved entries into
`gitops/workloads/<environment>/<workloadCellName>/artemis-values.yaml`, then
run `make validate-charts` and `make validate-topology`.

## Translation policy

The importer carries forward only settings with an explicit typed mapping:

| Chef shape | Candidate representation |
| --- | --- |
| OpenWire on `61616` | Required `artemis` acceptor with `CORE,OPENWIRE` |
| Other OpenWire, AMQP, STOMP, MQTT, WebSocket, and SSL transports | Named acceptors; TLS uses only supplied Kubernetes Secret references |
| Queue list | Durable ANYCAST addresses and queues |
| Exact topic authorization | MULTICAST address plus its authorization rule |
| Classic read roles | `consume` and `browse` |
| Classic write roles | `send` |
| Classic `>` wildcard | Artemis `#` wildcard |

Every generated listener, destination, and rule remains `candidate-review`
because a static Chef declaration cannot prove current client use. The default
policy also removes two common sources of inherited debt:

- `DLQ.*` queues are excluded because the chart already creates per-source
  dead-letter queues; and
- the `guests` role is excluded rather than preserving broad anonymous access.

Classic admin roles are recorded for review but receive no automatic create,
delete, or manage grants. Permanent destinations are pre-created, so those
operations require a separate least-privilege decision.

Use a per-environment policy file to encode cleanup decisions and rerun the
same source deterministically:

```json
{
  "schemaVersion": "chef-import-policy.artemis.apache.org/v1",
  "defaults": {
    "includeDlqDestinations": false,
    "dropRoles": ["guests"]
  },
  "brokers": {
    "legacy-internal": {
      "acceptorAllowlist": ["openwire", "amqp"],
      "excludeDestinations": ["RETIRED.*"],
      "excludeAuthorizationMatches": ["RETIRED.>"]
    }
  }
}
```

Pass it with `--policy /secure/review/AWSPP-policy.json`. Available policy
fields are `acceptorAllowlist`, `excludeAcceptors`, `destinationAllowlist`,
`excludeDestinations`, `authorizationAllowlist`,
`excludeAuthorizationMatches`, `dropRoles`, and
`includeDlqDestinations`. Patterns use shell-style matching. `--keep-role`
provides an explicit command-line exception to a dropped role.

Prefer allowlists when current connection, producer, and consumer evidence is
available. Exclusion lists are useful for known retirements, but they cannot
prove that every remaining declaration is live.

## Settings intentionally not copied

The report classifies legacy data instead of hiding it:

- `retired`: JDBC store/lock settings, remote JMX/RMI, legacy Jetty ownership,
  and cookbook/runtime flags replaced by the approved Artemis design;
- `manual`: positional transport tuning, Classic admin roles, Keycloak/Hawtio
  environment integration, identity/group reconciliation, and TLS material;
- `default-excluded` or `policy-excluded`: duplicate/DLQ entries, dropped
  roles, and explicit cleanup decisions; and
- `unsupported`: malformed or unmappable input that requires correction.

Legacy frame-size, inactivity, delay, NIO-pool, and prefetch values are not
positionally copied into Artemis. Give each one a named semantic mapping and
load-test evidence before adding an Artemis-specific tuning property.

## Secret and identity boundary

The importer reads the source locally but never emits password or token values,
certificate subjects, certificate aliases, private keys, users, or rendered
Secret data. The JSON report records sensitive key paths and counts only.

TLS listeners are omitted unless `--ssl-secret-name` is supplied. Certificate
users and groups must be reconciled into an externally materialized
`*-jaas-config` Secret; only the name supplied through `--jaas-secret-name`
enters the candidate. The source export and policy can contain sensitive
inventory, so keep both outside Git unless they have been separately sanitized.
