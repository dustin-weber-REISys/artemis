# ActiveMQ Classic 6.2.6 compatibility inventory

The supplied baseline is Classic `6.2.6`. Preserve OpenWire first; treat AMQP
modernization as a separate, reversible change. The repository inventory is
machine-readable at `tests/compatibility/classic-6.2.6-inventory.yaml`.

## Inventory inputs

Collect a sanitized broker configuration, destination list, runtime protocol
connection metrics, client library/version list, connection URLs, message
size/rate/retention, peak concurrency, and DLQ counts. Remove hostnames,
account IDs, Vault paths, certificates, credentials, and message bodies before
sharing evidence.

Confirm actual use of OpenWire `61616`, AMQP `5672`, STOMP `61613`, MQTT `1883`,
WebSocket `61614`, and console/Jolokia `8161`; the legacy listener list alone
does not prove application use.

## Required tests

- Durable anycast queues, selectors, redelivery, and one retained
  `DLQ.<source-address>` queue per source address.
- OpenWire send/consume using the existing client libraries.
- AMQP 1.0 send/consume with durable delivery and explicit acknowledgement.
- Duplicate retry using the stable `_AMQ_DUPL_ID` property.
- Focused tests for virtual topics, advisory consumers, wildcards, message
  groups, scheduled messages, durable topic subscriptions, XA, temporary
  destinations, and broker-specific management APIs.

Record each result as `pass`, `fail`, or `intentional-difference`, with a
reproduction command and owner. Do not declare compatibility from a successful
TCP connection alone. Existing clients should remain on OpenWire during the
first broker migration; move suitable integrations to AMQP only after the
OpenWire baseline and failover tests pass.
