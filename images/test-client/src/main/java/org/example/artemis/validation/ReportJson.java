package org.example.artemis.validation;

import java.time.Instant;
import java.util.List;

/** Dependency-free, stable JSON serialization for reports and shell tooling. */
public final class ReportJson {
    private ReportJson() {
    }

    public static String toJson(ValidationReport report) {
        StringBuilder json = new StringBuilder(1024);
        json.append('{');
        field(json, "schemaVersion", report.schemaVersion());
        field(json, "claim", report.claim());
        field(json, "operation", report.operation());
        field(json, "protocol", report.protocol());
        field(json, "destination", report.destination());
        field(json, "idPrefix", report.idPrefix());
        field(json, "runId", report.runId());
        field(json, "startedAt", report.startedAt());
        field(json, "completedAt", report.completedAt());
        number(json, "expectedStart", report.expectedStart());
        number(json, "expectedCount", report.expectedCount());
        number(json, "requestedCount", report.requestedCount());
        number(json, "acknowledgedCount", report.acknowledgedCount());
        number(json, "receivedCount", report.receivedCount());
        number(json, "uniqueCount", report.uniqueCount());
        number(json, "acknowledgementFailures", report.acknowledgementFailures());
        array(json, "missingSequences", report.missingSequences());
        array(json, "duplicateSequences", report.duplicateSequences());
        array(json, "redeliveredSequences", report.redeliveredSequences());
        array(json, "reorderedSequences", report.reorderedSequences());
        array(json, "unexpectedSequences", report.unexpectedSequences());
        array(json, "unacknowledgedSequences", report.unacknowledgedSequences());
        strings(json, "missingIds", report.missingIds());
        strings(json, "duplicateIds", report.duplicateIds());
        strings(json, "redeliveredIds", report.redeliveredIds());
        strings(json, "reorderedIds", report.reorderedIds());
        strings(json, "unexpectedIds", report.unexpectedIds());
        strings(json, "unacknowledgedIds", report.unacknowledgedIds());
        field(json, "status", report.status());
        field(json, "rpoStatus", report.rpoStatus());
        field(json, "notes", report.notes());
        json.append('}');
        return json.toString();
    }

    private static void field(StringBuilder json, String name, String value) {
        comma(json);
        string(json, name);
        json.append(':');
        string(json, value);
    }

    private static void field(StringBuilder json, String name, Instant value) {
        field(json, name, value == null ? null : value.toString());
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
