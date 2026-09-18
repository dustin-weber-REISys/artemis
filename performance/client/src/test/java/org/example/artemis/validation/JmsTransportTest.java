package org.example.artemis.validation;

import org.apache.activemq.ActiveMQConnectionFactory;
import org.apache.qpid.jms.JmsConnectionFactory;
import org.apache.qpid.jms.policy.JmsDefaultPresettlePolicy;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertInstanceOf;
import static org.junit.jupiter.api.Assertions.assertTrue;

class JmsTransportTest {
    @Test
    void openWireAlwaysUsesSynchronousSendsDespiteUriOptions() {
        ActiveMQConnectionFactory factory = assertInstanceOf(
                ActiveMQConnectionFactory.class,
                JmsTransport.synchronousFactory(
                        Protocol.OPENWIRE,
                        "tcp://localhost:61616?jms.useAsyncSend=true&jms.alwaysSyncSend=false"));

        assertFalse(factory.isUseAsyncSend());
        assertTrue(factory.isAlwaysSyncSend());
        assertFalse(factory.isSendAcksAsync());
    }

    @Test
    void amqpAlwaysUsesSettledSynchronousSendsDespiteUriOptions() {
        JmsConnectionFactory factory = assertInstanceOf(
                JmsConnectionFactory.class,
                JmsTransport.synchronousFactory(
                        Protocol.AMQP,
                        "amqp://localhost:5672?jms.forceAsyncSend=true"
                                + "&jms.forceSyncSend=false"
                                + "&jms.presettlePolicy.presettleAll=true"));

        assertFalse(factory.isForceAsyncSend());
        assertTrue(factory.isForceSyncSend());
        assertFalse(factory.isForceAsyncAcks());
        JmsDefaultPresettlePolicy policy =
                assertInstanceOf(JmsDefaultPresettlePolicy.class, factory.getPresettlePolicy());
        assertFalse(policy.isPresettleAll());
        assertFalse(policy.isPresettleProducers());
    }

    @Test
    void qpidAcceptsTheSupervisedTwoEndpointFailoverUri() {
        String uri = "failover:(amqp://host.docker.internal:25672,amqp://host.docker.internal:25673)"
                + "?failover.maxReconnectAttempts=-1"
                + "&failover.startupMaxReconnectAttempts=-1"
                + "&failover.initialReconnectDelay=100"
                + "&failover.reconnectDelay=1000"
                + "&failover.useReconnectBackOff=false";

        JmsConnectionFactory factory = assertInstanceOf(
                JmsConnectionFactory.class,
                JmsTransport.synchronousFactory(Protocol.AMQP, uri));

        assertEquals(uri, factory.getRemoteURI());
    }

    @Test
    void activeMqAcceptsTheSupervisedTwoEndpointFailoverUri() {
        String uri = "failover:(tcp://host.docker.internal:25672,tcp://host.docker.internal:25673)"
                + "?randomize=false"
                + "&maxReconnectAttempts=-1"
                + "&startupMaxReconnectAttempts=-1"
                + "&initialReconnectDelay=100"
                + "&reconnectDelay=1000";

        ActiveMQConnectionFactory factory = assertInstanceOf(
                ActiveMQConnectionFactory.class,
                JmsTransport.synchronousFactory(Protocol.OPENWIRE, uri));

        assertEquals(uri, factory.getBrokerURL());
    }
}
