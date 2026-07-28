package org.example.artemis.validation;

import java.util.Locale;

public final class MessageIds {
    private MessageIds() {
    }

    public static String id(String prefix, long sequence) {
        return prefix + String.format(Locale.ROOT, "%020d", sequence);
    }

    public static String body(String payloadPrefix, String id, long sequence, String duplicateId) {
        return "validation-v1|payload=" + payloadPrefix
                + "|id=" + id
                + "|sequence=" + sequence
                + "|duplicateId=" + duplicateId;
    }
}
