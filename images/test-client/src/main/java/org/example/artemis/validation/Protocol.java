package org.example.artemis.validation;

public enum Protocol {
    OPENWIRE,
    AMQP;

    public static Protocol parse(String value) {
        return switch (value.toLowerCase(java.util.Locale.ROOT)) {
            case "openwire", "open-wire" -> OPENWIRE;
            case "amqp", "amqp1", "amqp-1.0" -> AMQP;
            default -> throw new IllegalArgumentException("Unsupported protocol: " + value);
        };
    }
}
