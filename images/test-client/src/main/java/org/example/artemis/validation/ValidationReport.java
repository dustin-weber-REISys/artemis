package org.example.artemis.validation;

import java.time.Instant;
import java.util.List;

/** Machine-readable result shared by send and consume operations. */
public record ValidationReport(
        String schemaVersion,
        String claim,
        String operation,
        String protocol,
        String destination,
        String idPrefix,
        String runId,
        Instant startedAt,
        Instant completedAt,
        long expectedStart,
        long expectedCount,
        long requestedCount,
        long acknowledgedCount,
        long receivedCount,
        long uniqueCount,
        long acknowledgementFailures,
        List<Long> missingSequences,
        List<Long> duplicateSequences,
        List<Long> redeliveredSequences,
        List<Long> reorderedSequences,
        List<Long> unexpectedSequences,
        List<Long> unacknowledgedSequences,
        List<String> missingIds,
        List<String> duplicateIds,
        List<String> redeliveredIds,
        List<String> reorderedIds,
        List<String> unexpectedIds,
        List<String> unacknowledgedIds,
        String status,
        String rpoStatus,
        String notes) {

    public ValidationReport {
        if (idPrefix == null) {
            throw new IllegalArgumentException("idPrefix must not be null");
        }
        missingSequences = List.copyOf(missingSequences);
        duplicateSequences = List.copyOf(duplicateSequences);
        redeliveredSequences = List.copyOf(redeliveredSequences);
        reorderedSequences = List.copyOf(reorderedSequences);
        unexpectedSequences = List.copyOf(unexpectedSequences);
        unacknowledgedSequences = List.copyOf(unacknowledgedSequences);
        missingIds = List.copyOf(missingIds);
        duplicateIds = List.copyOf(duplicateIds);
        redeliveredIds = List.copyOf(redeliveredIds);
        reorderedIds = List.copyOf(reorderedIds);
        unexpectedIds = List.copyOf(unexpectedIds);
        unacknowledgedIds = List.copyOf(unacknowledgedIds);
    }

    public boolean successful() {
        return "PASS".equals(status);
    }
}
