package org.example.artemis.validation;

import org.junit.jupiter.api.Test;

import java.nio.file.Path;
import java.time.Duration;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertInstanceOf;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

class CommandLineTest {
    @Test
    void parsesSendOptionsIntoTypedCommand() {
        CommandLine.Command parsed = CommandLine.parse(new String[] {
                "send",
                "--protocol", "open-wire",
                "--url=tcp://broker:61616",
                "--destination", "validation.queue",
                "--count", "3",
                "--start-sequence", "20",
                "--payload-bytes", "1024",
                "--acknowledgement-ledger", "/reports/acknowledged.tsv",
                "--run-id", "run-1"
        });

        CommandLine.SendCommand send = assertInstanceOf(CommandLine.SendCommand.class, parsed);
        assertEquals(Protocol.OPENWIRE, send.common().protocol());
        assertEquals("tcp://broker:61616", send.common().url());
        assertEquals("validation-", send.common().idPrefix());
        assertEquals("run-1", send.common().runId());
        assertEquals(20, send.startSequence());
        assertEquals(3, send.count());
        assertEquals(1024, send.payloadBytes());
        assertEquals(Path.of("/reports/acknowledged.tsv"), send.acknowledgementLedger());
    }

    @Test
    void parsesConsumeDefaultsAndExplicitFalseFlag() {
        CommandLine.Command parsed = CommandLine.parse(new String[] {
                "consume",
                "--protocol", "amqp",
                "--url", "amqp://broker:5672",
                "--destination", "validation.queue",
                "--expected-count", "3",
                "--disconnect-before-ack=false"
        });

        CommandLine.ConsumeCommand consume =
                assertInstanceOf(CommandLine.ConsumeCommand.class, parsed);
        assertEquals(Duration.ofSeconds(5), consume.receiveTimeout());
        assertEquals(3, consume.maxMessages());
        assertEquals(0, consume.disconnectLimit());
        assertEquals(false, consume.disconnectBeforeAck());
    }

    @Test
    void operationSpecificAndUnknownOptionsAreRejected() {
        IllegalArgumentException sendOnly = assertThrows(
                IllegalArgumentException.class,
                () -> CommandLine.parse(new String[] {
                        "consume",
                        "--protocol", "amqp",
                        "--url", "amqp://broker:5672",
                        "--destination", "queue",
                        "--expected-count", "1",
                        "--start-sequence", "0"
                }));
        assertEquals("unknown option for consume: --start-sequence", sendOnly.getMessage());

        IllegalArgumentException unknown = assertThrows(
                IllegalArgumentException.class,
                () -> CommandLine.parse(new String[] {
                        "send",
                        "--protocol", "amqp",
                        "--url", "amqp://broker:5672",
                        "--destination", "queue",
                        "--count", "1",
                        "--typo", "value"
                }));
        assertEquals("unknown option for send: --typo", unknown.getMessage());
    }

    @Test
    void duplicateOptionsAndInvalidBooleanValuesAreRejected() {
        IllegalArgumentException duplicate = assertThrows(
                IllegalArgumentException.class,
                () -> CommandLine.parse(new String[] {
                        "send",
                        "--protocol", "amqp",
                        "--protocol", "openwire",
                        "--url", "amqp://broker:5672",
                        "--destination", "queue",
                        "--count", "1"
                }));
        assertEquals("duplicate option: --protocol", duplicate.getMessage());

        IllegalArgumentException invalidBoolean = assertThrows(
                IllegalArgumentException.class,
                () -> CommandLine.parse(new String[] {
                        "consume",
                        "--protocol", "amqp",
                        "--url", "amqp://broker:5672",
                        "--destination", "queue",
                        "--expected-count", "1",
                        "--disconnect-before-ack=sometimes"
                }));
        assertEquals(
                "--disconnect-before-ack must be true or false",
                invalidBoolean.getMessage());
    }

    @Test
    void helpIsDerivedFromTheAcceptedOptionDefinitions() {
        String usage = CommandLine.usage();

        assertTrue(usage.contains("--count N (required)"));
        assertTrue(usage.contains("--start-sequence N"));
        assertTrue(usage.contains("--payload-bytes N"));
        assertTrue(usage.contains("--acknowledgement-ledger FILE"));
        assertTrue(usage.contains("--expected-count N (required)"));
        assertTrue(usage.contains("--disconnect-before-ack"));
    }
}
