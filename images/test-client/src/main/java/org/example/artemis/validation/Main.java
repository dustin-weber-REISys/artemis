package org.example.artemis.validation;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.util.HashMap;
import java.util.Map;
import java.util.UUID;

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
        if (args.length == 0 || "help".equals(args[0]) || "--help".equals(args[0])) {
            usage();
            return 0;
        }
        String operation = args[0];
        Map<String, String> options = parseOptions(args, 1);
        Protocol protocol = Protocol.parse(required(options, "protocol"));
        String url = required(options, "url");
        String destination = required(options, "destination");
        String username = options.getOrDefault("username", "");
        String password = options.getOrDefault("password", "");
        String runId = options.getOrDefault("run-id", UUID.randomUUID().toString());
        Path output = options.containsKey("output") ? Path.of(options.get("output")) : null;

        ValidationReport report;
        try (JmsTransport transport = JmsTransport.connect(protocol, url, username, password)) {
            if ("send".equals(operation)) {
                long start = nonNegativeLong(options, "start-sequence", 0);
                long count = positiveLong(options, "count");
                DurableSendRunner.Config config = new DurableSendRunner.Config(
                        start,
                        count,
                        options.getOrDefault("id-prefix", "validation-"),
                        options.getOrDefault("duplicate-id-prefix", "validation-duplicate-"),
                        options.getOrDefault("payload-prefix", "deterministic"),
                        runId,
                        protocol,
                        destination);
                report = new DurableSendRunner().run(transport, config);
            } else if ("consume".equals(operation)) {
                long expectedStart = nonNegativeLong(options, "expected-start", 0);
                long expectedCount = positiveLong(options, "expected-count");
                long defaultMax = Math.addExact(expectedCount,
                        Boolean.parseBoolean(options.getOrDefault("disconnect-before-ack", "false")) ? 1 : 0);
                long maxMessages = nonNegativeLong(options, "max-messages", defaultMax);
                boolean disconnect = Boolean.parseBoolean(options.getOrDefault("disconnect-before-ack", "false"));
                long disconnectLimit = nonNegativeLong(options, "disconnect-limit", disconnect ? 1 : 0);
                long timeoutSeconds = positiveLong(options, "receive-timeout-seconds", 5);
                ConsumeRunner.Config config = new ConsumeRunner.Config(
                        expectedStart,
                        expectedCount,
                        maxMessages,
                        Duration.ofSeconds(timeoutSeconds),
                        disconnect,
                        disconnectLimit,
                        options.getOrDefault("id-prefix", "validation-"),
                        runId,
                        protocol,
                        destination);
                report = new ConsumeRunner().run(transport, config);
            } else {
                throw new IllegalArgumentException("operation must be send or consume");
            }
        }

        String json = ReportJson.toJson(report) + System.lineSeparator();
        if (output == null || "-".equals(output.toString())) {
            System.out.print(json);
        } else {
            Path parent = output.toAbsolutePath().getParent();
            if (parent != null) {
                Files.createDirectories(parent);
            }
            Files.writeString(output, json, StandardCharsets.UTF_8);
            System.out.println(json.trim());
        }
        return report.successful() ? 0 : 1;
    }

    private static Map<String, String> parseOptions(String[] args, int from) {
        Map<String, String> values = new HashMap<>();
        for (int index = from; index < args.length; index++) {
            String argument = args[index];
            if (!argument.startsWith("--")) {
                throw new IllegalArgumentException("unexpected argument: " + argument);
            }
            String option = argument.substring(2);
            if (option.isBlank()) {
                throw new IllegalArgumentException("empty option");
            }
            if (option.equals("disconnect-before-ack")) {
                values.put(option, "true");
                continue;
            }
            int equals = option.indexOf('=');
            if (equals >= 0) {
                values.put(option.substring(0, equals), option.substring(equals + 1));
                continue;
            }
            if (index + 1 >= args.length || args[index + 1].startsWith("--")) {
                throw new IllegalArgumentException("option requires a value: --" + option);
            }
            values.put(option, args[++index]);
        }
        return values;
    }

    private static String required(Map<String, String> options, String name) {
        String value = options.get(name);
        if (value == null || value.isBlank()) {
            throw new IllegalArgumentException("missing required option --" + name);
        }
        return value;
    }

    private static long positiveLong(Map<String, String> options, String name) {
        return positiveLong(options, name, Long.MIN_VALUE);
    }

    private static long positiveLong(Map<String, String> options, String name, long defaultValue) {
        String value = options.get(name);
        if (value == null) {
            if (defaultValue != Long.MIN_VALUE) {
                return defaultValue;
            }
            throw new IllegalArgumentException("missing required option --" + name);
        }
        try {
            long parsed = Long.parseLong(value);
            if (parsed <= 0) {
                throw new IllegalArgumentException("--" + name + " must be greater than zero");
            }
            return parsed;
        } catch (NumberFormatException invalid) {
            throw new IllegalArgumentException("--" + name + " must be an integer");
        }
    }

    private static long nonNegativeLong(Map<String, String> options, String name, long defaultValue) {
        String value = options.get(name);
        if (value == null) {
            return defaultValue;
        }
        try {
            long parsed = Long.parseLong(value);
            if (parsed < 0) {
                throw new IllegalArgumentException("--" + name + " must not be negative");
            }
            return parsed;
        } catch (NumberFormatException invalid) {
            throw new IllegalArgumentException("--" + name + " must be an integer");
        }
    }

    private static void usage() {
        System.err.println("Usage:");
        System.err.println("  validation-client send --protocol openwire|amqp --url URL --destination QUEUE --count N [options]");
        System.err.println("  validation-client consume --protocol openwire|amqp --url URL --destination QUEUE --expected-count N [options]");
        System.err.println("Options: --username USER --password PASS --output FILE --run-id ID --start-sequence N");
        System.err.println("         --id-prefix PREFIX --duplicate-id-prefix PREFIX --payload-prefix PREFIX");
        System.err.println("Consume: --expected-start N --max-messages N --receive-timeout-seconds N");
        System.err.println("        --disconnect-before-ack [--disconnect-limit N]");
    }
}
