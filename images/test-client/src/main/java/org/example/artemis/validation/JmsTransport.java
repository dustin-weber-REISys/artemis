package org.example.artemis.validation;

import jakarta.jms.Connection;
import jakarta.jms.ConnectionFactory;
import jakarta.jms.DeliveryMode;
import jakarta.jms.Destination;
import jakarta.jms.Message;
import jakarta.jms.MessageConsumer;
import jakarta.jms.MessageProducer;
import jakarta.jms.TextMessage;
import org.apache.activemq.ActiveMQConnectionFactory;
import org.apache.qpid.jms.JmsConnectionFactory;

import java.time.Duration;
import java.util.ArrayList;
import java.util.List;

/** JMS adapters: ActiveMQ Classic's OpenWire client and Apache Qpid JMS AMQP 1.0. */
public final class JmsTransport implements Transport {
    private final Connection connection;

    private JmsTransport(Connection connection) throws Exception {
        this.connection = connection;
        this.connection.start();
    }

    public static JmsTransport connect(Protocol protocol, String url, String username, String password)
            throws Exception {
        ConnectionFactory factory = switch (protocol) {
            case OPENWIRE -> new ActiveMQConnectionFactory(url);
            case AMQP -> new JmsConnectionFactory(url);
        };
        String effectiveUsername = username == null || username.isBlank() ? null : username;
        String effectivePassword = password == null || password.isBlank() ? null : password;
        return new JmsTransport(factory.createConnection(effectiveUsername, effectivePassword));
    }

    @Override
    public Transport.Session openSession() {
        return new JmsSession(connection);
    }

    @Override
    public void close() throws Exception {
        connection.close();
    }

    private static final class JmsSession implements Transport.Session {
        private final Connection connection;
        private final List<jakarta.jms.Session> sessions = new ArrayList<>();

        private JmsSession(Connection connection) {
            this.connection = connection;
        }

        @Override
        public synchronized Transport.Producer producer(String destination) throws Exception {
            jakarta.jms.Session session = connection.createSession(false, jakarta.jms.Session.AUTO_ACKNOWLEDGE);
            sessions.add(session);
            Destination queue = session.createQueue(destination);
            MessageProducer producer = session.createProducer(queue);
            producer.setDeliveryMode(DeliveryMode.PERSISTENT);
            return new JmsProducer(session, producer);
        }

        @Override
        public synchronized Transport.Consumer consumer(String destination) throws Exception {
            jakarta.jms.Session session = connection.createSession(false, jakarta.jms.Session.CLIENT_ACKNOWLEDGE);
            sessions.add(session);
            Destination queue = session.createQueue(destination);
            MessageConsumer consumer = session.createConsumer(queue);
            return new JmsConsumer(session, consumer);
        }

        @Override
        public synchronized void close() throws Exception {
            Exception first = null;
            for (jakarta.jms.Session session : sessions) {
                try {
                    session.close();
                } catch (Exception closeFailure) {
                    if (first == null) {
                        first = closeFailure;
                    } else {
                        first.addSuppressed(closeFailure);
                    }
                }
            }
            sessions.clear();
            if (first != null) {
                throw first;
            }
        }
    }

    private static final class JmsProducer implements Transport.Producer {
        private final jakarta.jms.Session session;
        private final MessageProducer producer;

        private JmsProducer(jakarta.jms.Session session, MessageProducer producer) {
            this.session = session;
            this.producer = producer;
        }

        @Override
        public void send(long sequence, String id, String duplicateId, String body) throws Exception {
            TextMessage message = session.createTextMessage(body);
            message.setStringProperty("validation.id", id);
            message.setLongProperty("validation.sequence", sequence);
            // Artemis duplicate detection uses this stable broker-visible property.
            message.setStringProperty("_AMQ_DUPL_ID", duplicateId);
            producer.send(message);
        }

        @Override
        public void close() throws Exception {
            try {
                producer.close();
            } finally {
                session.close();
            }
        }
    }

    private static final class JmsConsumer implements Transport.Consumer {
        private final jakarta.jms.Session session;
        private final MessageConsumer consumer;
        private boolean closed;

        private JmsConsumer(jakarta.jms.Session session, MessageConsumer consumer) {
            this.session = session;
            this.consumer = consumer;
        }

        @Override
        public Transport.Received receive(Duration timeout) throws Exception {
            if (closed) {
                throw new IllegalStateException("consumer is closed");
            }
            Message message = consumer.receive(timeout.toMillis());
            if (message == null) {
                return null;
            }
            String id = message.getStringProperty("validation.id");
            long sequence = message.getLongProperty("validation.sequence");
            String duplicateId = message.getStringProperty("_AMQ_DUPL_ID");
            return new JmsReceived(message, sequence, id, duplicateId, message.getJMSRedelivered());
        }

        @Override
        public void acknowledge(Transport.Received message) throws Exception {
            if (!(message instanceof JmsReceived jmsMessage)) {
                throw new IllegalArgumentException("message belongs to another transport");
            }
            jmsMessage.message().acknowledge();
        }

        @Override
        public void close() throws Exception {
            if (closed) {
                return;
            }
            closed = true;
            Exception first = null;
            try {
                consumer.close();
            } catch (Exception closeFailure) {
                first = closeFailure;
            }
            try {
                // Closing a CLIENT_ACKNOWLEDGE session before acknowledge makes the delivery eligible for retry.
                session.close();
            } catch (Exception closeFailure) {
                if (first == null) {
                    first = closeFailure;
                } else {
                    first.addSuppressed(closeFailure);
                }
            }
            if (first != null) {
                throw first;
            }
        }
    }

    private record JmsReceived(
            Message message,
            long sequence,
            String id,
            String duplicateId,
            boolean redelivered) implements Transport.Received {
    }
}
