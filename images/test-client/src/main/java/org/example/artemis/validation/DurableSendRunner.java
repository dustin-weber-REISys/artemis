package org.example.artemis.validation;

import java.time.Instant;
import java.util.ArrayList;
import java.util.List;

/** Sends persistent messages synchronously; send() returning is the ack boundary. */
public final class DurableSendRunner {
    public record Config(
            long startSequence,
            long count,
            String idPrefix,
            String duplicateIdPrefix,
            String payloadPrefix,
            String runId,
            Protocol protocol,
            String destination) {

        public Config {
            if (startSequence < 0 || count < 0) {
                throw new IllegalArgumentException("startSequence and count must be non-negative");
            }
            if (idPrefix == null || duplicateIdPrefix == null || payloadPrefix == null
                    || runId == null || protocol == null || destination == null) {
                throw new IllegalArgumentException("send configuration contains a null value");
            }
        }
    }

    public ValidationReport run(Transport transport, Config config) throws Exception {
        Instant startedAt = Instant.now();
        long acknowledged = 0;
        long failures = 0;
        List<Long> unacknowledged = new ArrayList<>();

        try (Transport.Session session = transport.openSession();
             Transport.Producer producer = session.producer(config.destination())) {
            for (long offset = 0; offset < config.count(); offset++) {
                long sequence = Math.addExact(config.startSequence(), offset);
                String id = MessageIds.id(config.idPrefix(), sequence);
                String duplicateId = MessageIds.id(config.duplicateIdPrefix(), sequence);
                String body = MessageIds.body(config.payloadPrefix(), id, sequence, duplicateId);
                try {
                    producer.send(sequence, id, duplicateId, body);
                    acknowledged++;
                } catch (Exception sendFailure) {
                    failures++;
                    unacknowledged.add(sequence);
                }
            }
        }

        return ValidationReport.forSend(
                new ValidationReport.RunContext(
                        config.protocol(),
                        config.destination(),
                        config.idPrefix(),
                        config.runId()),
                new ValidationReport.Timing(startedAt, Instant.now()),
                new ValidationReport.SendMetrics(
                        config.startSequence(),
                        config.count(),
                        acknowledged,
                        failures),
                unacknowledged);
    }
}
