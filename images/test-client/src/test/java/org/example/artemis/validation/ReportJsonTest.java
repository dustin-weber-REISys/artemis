package org.example.artemis.validation;

import org.junit.jupiter.api.Test;

import java.time.Instant;
import java.util.List;

import static org.junit.jupiter.api.Assertions.assertTrue;

class ReportJsonTest {
    @Test
    void reportSerializationIsStableAndEscapesValues() {
        ValidationReport report = new ValidationReport(
                "schema", "safety", "consume", "amqp", "queue\"name", "validation-", "run\\id",
                Instant.parse("2026-01-01T00:00:00Z"), Instant.parse("2026-01-01T00:00:01Z"),
                0, 1, 0, 1, 1, 1, 0, List.of(), List.of(0L), List.of(0L), List.of(), List.of(), List.of(),
                List.of(), List.of("validation-00000000000000000000"), List.of("validation-00000000000000000000"), List.of(), List.of(), List.of(),
                "PASS", "PASS", "line\nvalue");

        String json = ReportJson.toJson(report);

        assertTrue(json.contains("\"destination\":\"queue\\\"name\""));
        assertTrue(json.contains("\"runId\":\"run\\\\id\""));
        assertTrue(json.contains("\"duplicateSequences\":[0]"));
        assertTrue(json.contains("\"duplicateIds\":[\"validation-00000000000000000000\"]"));
        assertTrue(json.contains("\"notes\":\"line\\nvalue\""));
    }
}
