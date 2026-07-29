package org.example.artemis.validation;

import org.junit.jupiter.api.Test;

import java.time.Duration;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Deque;
import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

class RunnerTest {
    @Test
    void deliberateDisconnectProducesObservableRedelivery() throws Exception {
        FakeTransport transport = new FakeTransport(3);
        ValidationReport report = new ConsumeRunner().run(
                transport,
                new ConsumeRunner.Config(0, 3, 4, Duration.ofMillis(1), true, 1,
                        "validation-",
                        "run-1", Protocol.OPENWIRE, "validation.queue"));

        assertTrue(report.successful());
        assertEquals(Operation.CONSUME, report.context().operation());
        assertEquals(4, report.metrics().receivedCount());
        assertEquals(List.of(0L), report.findings().duplicate().sequences());
        assertEquals(List.of(0L), report.findings().redelivered().sequences());
        assertEquals(List.of("msg-0"), report.findings().duplicate().ids());
        assertEquals(List.of("msg-0"), report.findings().redelivered().ids());
        assertTrue(report.findings().missing().isEmpty());
        assertEquals(RpoStatus.PASS, report.outcome().rpoStatus());
        assertEquals(3, transport.acknowledged.size());
    }

    @Test
    void sendRunnerSeparatesAmbiguousOrFailedSendsFromAcknowledgements() throws Exception {
        FakeTransport transport = new FakeTransport(3);
        transport.failSequence = 21;
        ValidationReport report = new DurableSendRunner().run(
                transport,
                new DurableSendRunner.Config(20, 3, "msg-", "dup-", "body-",
                        "run-2", Protocol.AMQP, "validation.queue"));

        assertEquals(Operation.SEND, report.context().operation());
        assertEquals(2, report.metrics().acknowledgedCount());
        assertEquals(List.of(21L), report.findings().unacknowledged().sequences());
        assertEquals(
                List.of("msg-00000000000000000021"),
                report.findings().unacknowledged().ids());
        assertEquals(ReportStatus.FAIL, report.outcome().status());
        assertEquals(RpoStatus.NOT_EVALUATED, report.outcome().rpoStatus());
        assertEquals("msg-00000000000000000020", transport.sent.get(0).id());
        assertEquals("dup-00000000000000000022", transport.sent.get(2).duplicateId());
    }

    private record Sent(long sequence, String id, String duplicateId, String body) {
    }

    private static final class FakeTransport implements Transport {
        private final FakeSession session;
        private final Deque<Delivery> deliveries = new ArrayDeque<>();
        private final List<Sent> sent = new ArrayList<>();
        private final List<Long> acknowledged = new ArrayList<>();
        private long failSequence = Long.MIN_VALUE;

        private FakeTransport(int count) {
            for (int sequence = 0; sequence < count; sequence++) {
                deliveries.addLast(new Delivery(sequence, false));
            }
            session = new FakeSession();
        }

        @Override
        public Session openSession() {
            return session;
        }

        private final class FakeSession implements Session {
            @Override
            public Producer producer(String destination) {
                return new Producer() {
                    @Override
                    public void send(long sequence, String id, String duplicateId, String body) throws Exception {
                        sent.add(new Sent(sequence, id, duplicateId, body));
                        if (sequence == failSequence) {
                            throw new Exception("simulated ambiguous send");
                        }
                    }

                    @Override
                    public void close() {
                    }
                };
            }

            @Override
            public Consumer consumer(String destination) {
                return new FakeConsumer();
            }

            @Override
            public void close() {
            }
        }

        private final class FakeConsumer implements Consumer {
            private Delivery inFlight;
            private boolean closed;

            @Override
            public Received receive(Duration timeout) {
                if (closed) {
                    throw new IllegalStateException("closed consumer");
                }
                inFlight = deliveries.pollFirst();
                if (inFlight == null) {
                    return null;
                }
                return new BasicReceived(inFlight.sequence(), "msg-" + inFlight.sequence(),
                        "dup-" + inFlight.sequence(), inFlight.redelivered());
            }

            @Override
            public void acknowledge(Received message) {
                acknowledged.add(message.sequence());
                inFlight = null;
            }

            @Override
            public void close() {
                if (closed) {
                    return;
                }
                closed = true;
                if (inFlight != null) {
                    deliveries.addFirst(new Delivery(inFlight.sequence(), true));
                    inFlight = null;
                }
            }
        }

        private record Delivery(long sequence, boolean redelivered) {
        }
    }
}
