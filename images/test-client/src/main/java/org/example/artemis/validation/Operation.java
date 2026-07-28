package org.example.artemis.validation;

import java.util.Locale;

/** Supported client operation and its machine-readable report value. */
public enum Operation {
    SEND("send"),
    CONSUME("consume");

    private final String reportValue;

    Operation(String reportValue) {
        this.reportValue = reportValue;
    }

    public String reportValue() {
        return reportValue;
    }

    public static Operation parse(String value) {
        return switch (value.toLowerCase(Locale.ROOT)) {
            case "send" -> SEND;
            case "consume" -> CONSUME;
            default -> throw new IllegalArgumentException("operation must be send or consume");
        };
    }
}
