package org.example.artemis.validation;

import java.time.Duration;
import java.time.Instant;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

/** Receives with explicit acknowledgements and can force a close before ack. */
public final class ConsumeRunner {
    public record Config(
            long expectedStart,
            long expectedCount,
            long maxMessages,
            Duration receiveTimeout,
            boolean disconnectBeforeAck,
            long disconnectLimit,
            String idPrefix,
            String runId,
            Protocol protocol,
            String destination) {

        public Config {
            if (expectedStart < 0 || expectedCount < 0 || maxMessages < 0 || disconnectLimit < 0) {
                throw new IllegalArgumentException("consume counts must be non-negative");
            }
            if (receiveTimeout.isNegative() || receiveTimeout.isZero()) {
                throw new IllegalArgumentException("receiveTimeout must be positive");
            }
            if (idPrefix == null || runId == null || protocol == null || destination == null) {
                throw new IllegalArgumentException("consume configuration contains a null value");
            }
        }
    }

    public ValidationReport run(Transport transport, Config config) throws Exception {
        Instant startedAt = Instant.now();
        SequenceTracker tracker = new SequenceTracker(config.expectedStart(), config.expectedCount());
        Set<Long> pendingAcknowledgement = new HashSet<>();
        long acknowledged = 0;
        long acknowledgementFailures = 0;
        long disconnects = 0;
        long received = 0;

        try (Transport.Session session = transport.openSession()) {
            Transport.Consumer consumer = session.consumer(config.destination());
            try {
                while (received < config.maxMessages()
                        && (tracker.uniqueCount() < config.expectedCount() || !pendingAcknowledgement.isEmpty())) {
                    Transport.Received message = consumer.receive(config.receiveTimeout());
                    if (message == null) {
                        break;
                    }
                    received++;
                    tracker.observe(message.sequence(), message.id(), message.redelivered());

                    if (config.disconnectBeforeAck() && disconnects < config.disconnectLimit()
                            && !pendingAcknowledgement.contains(message.sequence())) {
                        pendingAcknowledgement.add(message.sequence());
                        disconnects++;
                        consumer.close();
                        consumer = session.consumer(config.destination());
                        continue;
                    }

                    try {
                        consumer.acknowledge(message);
                        acknowledged++;
                        pendingAcknowledgement.remove(message.sequence());
                    } catch (Exception acknowledgementFailure) {
                        acknowledgementFailures++;
                        pendingAcknowledgement.add(message.sequence());
                    }
                }
            } finally {
                consumer.close();
            }
        }

        List<Long> unacknowledged = new ArrayList<>(pendingAcknowledgement);
        unacknowledged.sort(Long::compareTo);
        return ValidationReport.forConsume(
                new ValidationReport.RunContext(
                        config.protocol(),
                        config.destination(),
                        config.idPrefix(),
                        config.runId()),
                new ValidationReport.Timing(startedAt, Instant.now()),
                new ValidationReport.ConsumeMetrics(
                        config.expectedStart(),
                        config.expectedCount(),
                        acknowledged,
                        tracker.receivedCount(),
                        tracker.uniqueCount(),
                        acknowledgementFailures),
                ValidationReport.Findings.from(tracker, unacknowledged, config.idPrefix()),
                disconnects);
    }
}
