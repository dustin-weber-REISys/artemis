package org.example.artemis.validation;

import org.junit.jupiter.api.Test;

import java.time.Instant;
import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;

class ReportJsonTest {
    @Test
    void nestedReportProjectsToStableFlatV1JsonAndEscapesValues() {
        ValidationReport.Finding none = new ValidationReport.Finding(List.of(), List.of());
        ValidationReport report = new ValidationReport(
                "schema",
                new ValidationReport.Context(
                        Claim.SAFETY,
                        Operation.CONSUME,
                        Protocol.AMQP,
                        "queue\"name",
                        "validation-",
                        "run\\id"),
                new ValidationReport.Timing(
                        Instant.parse("2026-01-01T00:00:00Z"),
                        Instant.parse("2026-01-01T00:00:01Z")),
                new ValidationReport.Metrics(0, 1, 0, 1, 1, 1, 0),
                new ValidationReport.Findings(
                        none,
                        new ValidationReport.Finding(
                                List.of(0L),
                                List.of("validation-00000000000000000000")),
                        new ValidationReport.Finding(
                                List.of(0L),
                                List.of("validation-00000000000000000000")),
                        none,
                        none,
                        none),
                new ValidationReport.Outcome(
                        ReportStatus.PASS,
                        RpoStatus.PASS,
                        "line\nvalue"));

        String json = ReportJson.toJson(report);

        assertEquals(
                "{\"schemaVersion\":\"schema\",\"claim\":\"safety\",\"operation\":\"consume\","
                        + "\"protocol\":\"amqp\",\"destination\":\"queue\\\"name\","
                        + "\"idPrefix\":\"validation-\",\"runId\":\"run\\\\id\","
                        + "\"startedAt\":\"2026-01-01T00:00:00Z\","
                        + "\"completedAt\":\"2026-01-01T00:00:01Z\","
                        + "\"expectedStart\":0,\"expectedCount\":1,\"requestedCount\":0,"
                        + "\"acknowledgedCount\":1,\"receivedCount\":1,\"uniqueCount\":1,"
                        + "\"acknowledgementFailures\":0,\"missingSequences\":[],"
                        + "\"duplicateSequences\":[0],\"redeliveredSequences\":[0],"
                        + "\"reorderedSequences\":[],\"unexpectedSequences\":[],"
                        + "\"unacknowledgedSequences\":[],\"missingIds\":[],"
                        + "\"duplicateIds\":[\"validation-00000000000000000000\"],"
                        + "\"redeliveredIds\":[\"validation-00000000000000000000\"],"
                        + "\"reorderedIds\":[],\"unexpectedIds\":[],\"unacknowledgedIds\":[],"
                        + "\"status\":\"PASS\",\"rpoStatus\":\"PASS\",\"notes\":\"line\\nvalue\"}",
                json);
    }
}
