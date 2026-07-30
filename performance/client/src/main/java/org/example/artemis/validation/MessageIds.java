package org.example.artemis.validation;

import java.nio.charset.StandardCharsets;
import java.util.Locale;

public final class MessageIds {
    private MessageIds() {
    }

    public static String id(String prefix, long sequence) {
        return prefix + String.format(Locale.ROOT, "%020d", sequence);
    }

    public static String body(
            String payloadPrefix,
            String id,
            long sequence,
            String duplicateId,
            int payloadBytes) {
        String metadata = "validation-v1|payload=" + payloadPrefix
                + "|id=" + id
                + "|sequence=" + sequence
                + "|duplicateId=" + duplicateId;
        int metadataBytes = metadata.getBytes(StandardCharsets.UTF_8).length;
        if (metadataBytes > payloadBytes) {
            throw new IllegalArgumentException(
                    "payloadBytes " + payloadBytes
                            + " is smaller than message metadata " + metadataBytes);
        }
        return metadata + "x".repeat(payloadBytes - metadataBytes);
    }
}
