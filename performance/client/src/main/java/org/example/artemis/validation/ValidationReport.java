package org.example.artemis.validation;

import java.time.Instant;
import java.util.List;
import java.util.Objects;

/** Typed domain model for the stable, machine-readable validation report. */
public record ValidationReport(
        String schemaVersion,
        Context context,
        Timing timing,
        Metrics metrics,
        Findings findings,
        Outcome outcome) {

    public static final String SCHEMA_VERSION = "validation.artemis.apache.org/v1";
    public static final String SEND_NOTES =
            "Persistent send acknowledgement is synchronous; broker-acknowledged IDs are the RPO baseline, not an RPO verdict.";

    public ValidationReport {
        Objects.requireNonNull(schemaVersion, "schemaVersion");
        Objects.requireNonNull(context, "context");
        Objects.requireNonNull(timing, "timing");
        Objects.requireNonNull(metrics, "metrics");
        Objects.requireNonNull(findings, "findings");
        Objects.requireNonNull(outcome, "outcome");
    }

    public static ValidationReport forSend(
            RunContext run,
            Timing timing,
            SendMetrics send,
            List<Long> unacknowledgedSequences) {
        List<Long> sequences = List.copyOf(unacknowledgedSequences);
        Findings findings = Findings.onlyUnacknowledged(
                sequences,
                sequences.stream()
                        .map(sequence -> MessageIds.id(run.idPrefix(), sequence))
                        .toList());
        boolean pass = send.acknowledgementFailures() == 0;
        return new ValidationReport(
                SCHEMA_VERSION,
                run.forOperation(Operation.SEND),
                timing,
                send.asReportMetrics(),
                findings,
                new Outcome(
                        pass ? ReportStatus.PASS : ReportStatus.FAIL,
                        RpoStatus.NOT_EVALUATED,
                        SEND_NOTES));
    }

    public static ValidationReport forConsume(
            RunContext run,
            Timing timing,
            ConsumeMetrics consume,
            Findings findings,
            long disconnectsBeforeAck) {
        boolean pass = findings.missing().isEmpty()
                && findings.unacknowledged().isEmpty()
                && findings.unexpected().isEmpty()
                && consume.acknowledgementFailures() == 0;
        return new ValidationReport(
                SCHEMA_VERSION,
                run.forOperation(Operation.CONSUME),
                timing,
                consume.asReportMetrics(),
                findings,
                new Outcome(
                        pass ? ReportStatus.PASS : ReportStatus.FAIL,
                        pass ? RpoStatus.PASS : RpoStatus.FAIL,
                        "disconnectsBeforeAck=" + disconnectsBeforeAck
                                + "; at-least-once delivery is expected, so duplicates are reported rather than treated as loss."));
    }

    public boolean successful() {
        return outcome.status() == ReportStatus.PASS;
    }

    public record RunContext(Protocol protocol, String destination, String idPrefix, String runId) {
        public RunContext {
            Objects.requireNonNull(protocol, "protocol");
            Objects.requireNonNull(destination, "destination");
            Objects.requireNonNull(idPrefix, "idPrefix");
            Objects.requireNonNull(runId, "runId");
        }

        private Context forOperation(Operation operation) {
            return new Context(Claim.SAFETY, operation, protocol, destination, idPrefix, runId);
        }
    }

    public record Context(
            Claim claim,
            Operation operation,
            Protocol protocol,
            String destination,
            String idPrefix,
            String runId) {
        public Context {
            Objects.requireNonNull(claim, "claim");
            Objects.requireNonNull(operation, "operation");
            Objects.requireNonNull(protocol, "protocol");
            Objects.requireNonNull(destination, "destination");
            Objects.requireNonNull(idPrefix, "idPrefix");
            Objects.requireNonNull(runId, "runId");
        }
    }

    public record Timing(Instant startedAt, Instant completedAt) {
        public Timing {
            Objects.requireNonNull(startedAt, "startedAt");
            Objects.requireNonNull(completedAt, "completedAt");
        }
    }

    public record SendMetrics(
            long startSequence,
            long requestedCount,
            long acknowledgedCount,
            long acknowledgementFailures) {
        public SendMetrics {
            requireNonNegative(startSequence, "startSequence");
            requireNonNegative(requestedCount, "requestedCount");
            requireNonNegative(acknowledgedCount, "acknowledgedCount");
            requireNonNegative(acknowledgementFailures, "acknowledgementFailures");
            if (Math.addExact(acknowledgedCount, acknowledgementFailures) != requestedCount) {
                throw new IllegalArgumentException(
                        "acknowledgedCount plus acknowledgementFailures must equal requestedCount");
            }
        }

        private Metrics asReportMetrics() {
            return new Metrics(
                    startSequence,
                    requestedCount,
                    requestedCount,
                    acknowledgedCount,
                    0,
                    0,
                    acknowledgementFailures);
        }
    }

    public record ConsumeMetrics(
            long expectedStart,
            long expectedCount,
            long acknowledgedCount,
            long receivedCount,
            long uniqueCount,
            long acknowledgementFailures) {
        public ConsumeMetrics {
            requireNonNegative(expectedStart, "expectedStart");
            requireNonNegative(expectedCount, "expectedCount");
            requireNonNegative(acknowledgedCount, "acknowledgedCount");
            requireNonNegative(receivedCount, "receivedCount");
            requireNonNegative(uniqueCount, "uniqueCount");
            requireNonNegative(acknowledgementFailures, "acknowledgementFailures");
            if (uniqueCount > receivedCount) {
                throw new IllegalArgumentException("uniqueCount must not exceed receivedCount");
            }
        }

        private Metrics asReportMetrics() {
            return new Metrics(
                    expectedStart,
                    expectedCount,
                    0,
                    acknowledgedCount,
                    receivedCount,
                    uniqueCount,
                    acknowledgementFailures);
        }
    }

    /** Flat counters retained by the v1 report contract. */
    public record Metrics(
            long expectedStart,
            long expectedCount,
            long requestedCount,
            long acknowledgedCount,
            long receivedCount,
            long uniqueCount,
            long acknowledgementFailures) {
        public Metrics {
            requireNonNegative(expectedStart, "expectedStart");
            requireNonNegative(expectedCount, "expectedCount");
            requireNonNegative(requestedCount, "requestedCount");
            requireNonNegative(acknowledgedCount, "acknowledgedCount");
            requireNonNegative(receivedCount, "receivedCount");
            requireNonNegative(uniqueCount, "uniqueCount");
            requireNonNegative(acknowledgementFailures, "acknowledgementFailures");
        }
    }

    public record Finding(List<Long> sequences, List<String> ids) {
        private static final Finding NONE = new Finding(List.of(), List.of());

        public Finding {
            sequences = List.copyOf(sequences);
            ids = List.copyOf(ids);
        }

        public boolean isEmpty() {
            return sequences.isEmpty() && ids.isEmpty();
        }
    }

    public record Findings(
            Finding missing,
            Finding duplicate,
            Finding redelivered,
            Finding reordered,
            Finding unexpected,
            Finding unacknowledged) {
        public Findings {
            Objects.requireNonNull(missing, "missing");
            Objects.requireNonNull(duplicate, "duplicate");
            Objects.requireNonNull(redelivered, "redelivered");
            Objects.requireNonNull(reordered, "reordered");
            Objects.requireNonNull(unexpected, "unexpected");
            Objects.requireNonNull(unacknowledged, "unacknowledged");
        }

        public static Findings onlyUnacknowledged(List<Long> sequences, List<String> ids) {
            return new Findings(
                    Finding.NONE,
                    Finding.NONE,
                    Finding.NONE,
                    Finding.NONE,
                    Finding.NONE,
                    new Finding(sequences, ids));
        }

        public static Findings from(
                SequenceTracker tracker,
                List<Long> unacknowledgedSequences,
                String idPrefix) {
            return new Findings(
                    new Finding(tracker.missingSequences(), tracker.missingIds(idPrefix)),
                    new Finding(tracker.duplicateSequences(), tracker.duplicateIds()),
                    new Finding(tracker.redeliveredSequences(), tracker.redeliveredIds()),
                    new Finding(tracker.reorderedSequences(), tracker.reorderedIds()),
                    new Finding(tracker.unexpectedSequences(), tracker.unexpectedIds()),
                    new Finding(
                            unacknowledgedSequences,
                            tracker.idsForSequences(unacknowledgedSequences, idPrefix)));
        }
    }

    public record Outcome(ReportStatus status, RpoStatus rpoStatus, String notes) {
        public Outcome {
            Objects.requireNonNull(status, "status");
            Objects.requireNonNull(rpoStatus, "rpoStatus");
            Objects.requireNonNull(notes, "notes");
        }
    }

    private static void requireNonNegative(long value, String name) {
        if (value < 0) {
            throw new IllegalArgumentException(name + " must be non-negative");
        }
    }
}
