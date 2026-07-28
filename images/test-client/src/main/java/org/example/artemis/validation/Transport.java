package org.example.artemis.validation;

import java.time.Duration;

/** Small provider-neutral surface used by the deterministic test runners. */
public interface Transport extends AutoCloseable {
    Session openSession() throws Exception;

    @Override
    default void close() throws Exception {
    }

    interface Session extends AutoCloseable {
        Producer producer(String destination) throws Exception;

        Consumer consumer(String destination) throws Exception;

        @Override
        void close() throws Exception;
    }

    interface Producer extends AutoCloseable {
        /** Returning normally is the broker acknowledgement boundary. */
        void send(long sequence, String id, String duplicateId, String body) throws Exception;

        @Override
        void close() throws Exception;
    }

    interface Consumer extends AutoCloseable {
        Received receive(Duration timeout) throws Exception;

        void acknowledge(Received message) throws Exception;

        /** Close the delivery session without acknowledging the supplied message. */
        @Override
        void close() throws Exception;
    }

    interface Received {
        long sequence();

        String id();

        String duplicateId();

        boolean redelivered();
    }

    record BasicReceived(long sequence, String id, String duplicateId, boolean redelivered) implements Received {
    }
}
