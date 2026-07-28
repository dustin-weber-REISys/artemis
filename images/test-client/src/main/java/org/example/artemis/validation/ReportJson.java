package org.example.artemis.validation;

import java.util.List;

/**
 * Stable v1 JSON projection for reports and shell tooling.
 *
 * <p>The explicit projection keeps the external flat schema independent from the
 * nested domain model without adding a general-purpose JSON dependency to the
 * runtime image.
 */
public final class ReportJson {
    private ReportJson() {
    }

    public static String toJson(ValidationReport report) {
        ValidationReport.Context context = report.context();
        ValidationReport.Timing timing = report.timing();
        ValidationReport.Metrics metrics = report.metrics();
        ValidationReport.Findings findings = report.findings();
        ValidationReport.Outcome outcome = report.outcome();

        StringBuilder json = new StringBuilder(1024);
        json.append('{');
        field(json, "schemaVersion", report.schemaVersion());
        field(json, "claim", context.claim().reportValue());
        field(json, "operation", context.operation().reportValue());
        field(json, "protocol", context.protocol().reportValue());
        field(json, "destination", context.destination());
        field(json, "idPrefix", context.idPrefix());
        field(json, "runId", context.runId());
        field(json, "startedAt", timing.startedAt().toString());
        field(json, "completedAt", timing.completedAt().toString());
        number(json, "expectedStart", metrics.expectedStart());
        number(json, "expectedCount", metrics.expectedCount());
        number(json, "requestedCount", metrics.requestedCount());
        number(json, "acknowledgedCount", metrics.acknowledgedCount());
        number(json, "receivedCount", metrics.receivedCount());
        number(json, "uniqueCount", metrics.uniqueCount());
        number(json, "acknowledgementFailures", metrics.acknowledgementFailures());
        findingSequences(json, "missingSequences", findings.missing());
        findingSequences(json, "duplicateSequences", findings.duplicate());
        findingSequences(json, "redeliveredSequences", findings.redelivered());
        findingSequences(json, "reorderedSequences", findings.reordered());
        findingSequences(json, "unexpectedSequences", findings.unexpected());
        findingSequences(json, "unacknowledgedSequences", findings.unacknowledged());
        findingIds(json, "missingIds", findings.missing());
        findingIds(json, "duplicateIds", findings.duplicate());
        findingIds(json, "redeliveredIds", findings.redelivered());
        findingIds(json, "reorderedIds", findings.reordered());
        findingIds(json, "unexpectedIds", findings.unexpected());
        findingIds(json, "unacknowledgedIds", findings.unacknowledged());
        field(json, "status", outcome.status().reportValue());
        field(json, "rpoStatus", outcome.rpoStatus().reportValue());
        field(json, "notes", outcome.notes());
        json.append('}');
        return json.toString();
    }

    private static void field(StringBuilder json, String name, String value) {
        comma(json);
        string(json, name);
        json.append(':');
        string(json, value);
    }

    private static void findingSequences(
            StringBuilder json,
            String name,
            ValidationReport.Finding finding) {
        array(json, name, finding.sequences());
    }

    private static void findingIds(
            StringBuilder json,
            String name,
            ValidationReport.Finding finding) {
        strings(json, name, finding.ids());
    }

    private static void number(StringBuilder json, String name, long value) {
        comma(json);
        string(json, name);
        json.append(':').append(value);
    }

    private static void array(StringBuilder json, String name, List<Long> values) {
        comma(json);
        string(json, name);
        json.append(':').append('[');
        for (int index = 0; index < values.size(); index++) {
            if (index > 0) {
                json.append(',');
            }
            json.append(values.get(index));
        }
        json.append(']');
    }

    private static void strings(StringBuilder json, String name, List<String> values) {
        comma(json);
        string(json, name);
        json.append(':').append('[');
        for (int index = 0; index < values.size(); index++) {
            if (index > 0) {
                json.append(',');
            }
            string(json, values.get(index));
        }
        json.append(']');
    }

    private static void string(StringBuilder json, String value) {
        if (value == null) {
            json.append("null");
            return;
        }
        json.append('"');
        for (int index = 0; index < value.length(); index++) {
            char character = value.charAt(index);
            switch (character) {
                case '"' -> json.append("\\\"");
                case '\\' -> json.append("\\\\");
                case '\b' -> json.append("\\b");
                case '\f' -> json.append("\\f");
                case '\n' -> json.append("\\n");
                case '\r' -> json.append("\\r");
                case '\t' -> json.append("\\t");
                default -> {
                    if (character < 0x20) {
                        json.append(String.format("\\u%04x", (int) character));
                    } else {
                        json.append(character);
                    }
                }
            }
        }
        json.append('"');
    }

    private static void comma(StringBuilder json) {
        if (json.length() > 1) {
            json.append(',');
        }
    }
}
