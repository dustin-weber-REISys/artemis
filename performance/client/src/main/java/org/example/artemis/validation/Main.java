package org.example.artemis.validation;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

public final class Main {
    private Main() {
    }

    public static void main(String[] args) throws Exception {
        int exitCode;
        try {
            exitCode = new Main().run(args);
        } catch (IllegalArgumentException usageFailure) {
            System.err.println("validation-client: " + usageFailure.getMessage());
            usage();
            exitCode = 2;
        } catch (Exception failure) {
            System.err.println("validation-client: operation failed: " + failure.getMessage());
            exitCode = 2;
        }
        if (exitCode != 0) {
            System.exit(exitCode);
        }
    }

    int run(String[] args) throws Exception {
        if (CommandLine.isHelpRequest(args)) {
            usage();
            return 0;
        }

        CommandLine.Command command = CommandLine.parse(args);
        CommandLine.Common common = command.common();
        ValidationReport report;
        try (JmsTransport transport = JmsTransport.connect(
                common.protocol(),
                common.url(),
                common.username(),
                common.password())) {
            if (command instanceof CommandLine.SendCommand send) {
                DurableSendRunner.Config config = new DurableSendRunner.Config(
                        send.startSequence(),
                        send.count(),
                        common.idPrefix(),
                        send.duplicateIdPrefix(),
                        send.payloadPrefix(),
                        send.payloadBytes(),
                        common.runId(),
                        common.protocol(),
                        common.destination());
                if (send.acknowledgementLedger() == null) {
                    report = new DurableSendRunner().run(transport, config);
                } else {
                    try (AcknowledgementLedger ledger =
                                 AcknowledgementLedger.open(send.acknowledgementLedger())) {
                        report = new DurableSendRunner().run(transport, config, ledger);
                    }
                }
            } else {
                CommandLine.ConsumeCommand consume = (CommandLine.ConsumeCommand) command;
                ConsumeRunner.Config config = new ConsumeRunner.Config(
                        consume.expectedStart(),
                        consume.expectedCount(),
                        consume.maxMessages(),
                        consume.receiveTimeout(),
                        consume.disconnectBeforeAck(),
                        consume.disconnectLimit(),
                        common.idPrefix(),
                        common.runId(),
                        common.protocol(),
                        common.destination());
                report = new ConsumeRunner().run(transport, config);
            }
        }

        writeReport(report, common.output());
        return report.successful() ? 0 : 1;
    }

    private static void writeReport(ValidationReport report, Path output) throws Exception {
        String json = ReportJson.toJson(report) + System.lineSeparator();
        if (output == null || "-".equals(output.toString())) {
            System.out.print(json);
            return;
        }

        Path parent = output.toAbsolutePath().getParent();
        if (parent != null) {
            Files.createDirectories(parent);
        }
        Files.writeString(output, json, StandardCharsets.UTF_8);
        System.out.println(json.trim());
    }

    private static void usage() {
        System.err.print(CommandLine.usage());
    }
}
