# Deterministic validation client

This image is a small, open-source JMS client for repeatable Artemis HA tests.
It uses ActiveMQ Classic `6.2.6` for OpenWire and Apache Qpid JMS `2.10.0` for
AMQP 1.0. Both are Jakarta Messaging clients; no protocol frames are built by
hand.

The client sends persistent messages synchronously. Each message contains
deterministic `validation_id`, `validation_sequence`, and `_AMQ_DUPL_ID`
properties. The underscore-form validation names are valid across both
OpenWire and AMQP JMS clients. The consumer uses `CLIENT_ACKNOWLEDGE`, can
close its delivery session before ack, and reports missing, duplicate,
redelivered, reordered, unexpected, and
unacknowledged sequence numbers.
Reports include both sequence-number arrays and literal deterministic ID arrays
(`missingIds`, `duplicateIds`, `redeliveredIds`, `reorderedIds`,
`unexpectedIds`, and `unacknowledgedIds`).

Example commands (use environment-supplied URLs and credentials):

```text
java -cp 'client.jar:lib/*' org.example.artemis.validation.Main send \
  --protocol openwire --url 'tcp://broker.example.invalid:61616' \
  --destination validation.queue --count 100000 --output send.json

java -cp 'client.jar:lib/*' org.example.artemis.validation.Main consume \
  --protocol amqp --url 'amqp://broker.example.invalid:5672' \
  --destination validation.queue --expected-count 100000 \
  --disconnect-before-ack --output consume.json
```

The placeholder hostname above is intentionally non-routable. Supply real
values only through a test-job secret or environment-specific deployment; do
not put credentials in Git, rendered manifests, or shell history.

The Dockerfile requires immutable build and runtime digests. The promotion
pipeline should record the source version, digest, SBOM, license inventory, and
scan result alongside the mirrored image.
