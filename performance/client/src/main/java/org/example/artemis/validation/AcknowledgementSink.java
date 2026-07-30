package org.example.artemis.validation;

/** Receives a message ID immediately after its persistent send returns successfully. */
@FunctionalInterface
public interface AcknowledgementSink {
    AcknowledgementSink NONE = (sequence, id) -> { };

    void record(long sequence, String id) throws Exception;
}
