package org.example.artemis.validation;

import org.apache.activemq.ActiveMQConnectionFactory;
import org.apache.qpid.jms.JmsConnectionFactory;
import org.apache.qpid.jms.policy.JmsDefaultPresettlePolicy;
import org.junit.jupiter.api.Test;

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
}
