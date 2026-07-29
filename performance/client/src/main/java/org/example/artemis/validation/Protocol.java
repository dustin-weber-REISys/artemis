package org.example.artemis.validation;

public enum Protocol {
    OPENWIRE("openwire"),
    AMQP("amqp");

    private final String reportValue;

    Protocol(String reportValue) {
        this.reportValue = reportValue;
    }

    public String reportValue() {
        return reportValue;
    }

    public static Protocol parse(String value) {
        return switch (value.toLowerCase(java.util.Locale.ROOT)) {
            case "openwire", "open-wire" -> OPENWIRE;
            case "amqp", "amqp1", "amqp-1.0" -> AMQP;
            default -> throw new IllegalArgumentException("Unsupported protocol: " + value);
        };
    }
}
