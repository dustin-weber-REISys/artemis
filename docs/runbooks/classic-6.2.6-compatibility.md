# ActiveMQ Classic 6.2.6 compatibility inventory

The supplied baseline is Classic `6.2.6`. Preserve OpenWire first; treat
protocol modernization as a separate, reversible change. The authoritative
listener, client-library, and feature inventory is
[`tests/compatibility/classic-6.2.6-inventory.yaml`](../../tests/compatibility/classic-6.2.6-inventory.yaml).

## Inventory inputs

Collect a sanitized broker configuration, destination list, runtime protocol
connection metrics, client library/version list, connection URLs, message
size/rate/retention, peak concurrency, and DLQ counts. Remove hostnames,
account IDs, Vault paths, certificates, credentials, and message bodies before
sharing evidence.

Confirm actual runtime use of every configured listener; a legacy listener
definition alone does not prove application use.

## Required tests

Execute every required and focused case in the machine-readable inventory with
the existing client libraries. Cover durable send/consume, explicit
acknowledgement, redelivery and dead-letter behavior, stable duplicate retry,
and each Classic-specific feature found during runtime inventory.

Record each result as `pass`, `fail`, or `intentional-difference`, with a
reproduction command and owner. Do not declare compatibility from a successful
TCP connection alone. Existing clients should remain on OpenWire during the
first broker migration; move suitable integrations to AMQP only after the
OpenWire baseline and failover tests pass.
