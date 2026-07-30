package org.example.artemis.validation;

import java.nio.file.Path;
import java.time.Duration;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/** Parses operation-specific options into typed commands and generates CLI help. */
final class CommandLine {
    private static final List<Option> COMMON_OPTIONS = List.of(
            required("protocol", "openwire|amqp", "JMS wire protocol"),
            required("url", "URL", "Broker connection URL"),
            required("destination", "QUEUE", "Queue name"),
            optional("username", "USER", "Broker username"),
            optional("password", "PASS", "Broker password"),
            optional("run-id", "ID", "Run identifier (default: random UUID)"),
            optional("output", "FILE", "Write JSON to FILE; use - for stdout"),
            optional("id-prefix", "PREFIX", "Deterministic message ID prefix"));

    private static final List<Option> SEND_OPTIONS = List.of(
            required("count", "N", "Number of persistent messages to send"),
            optional("start-sequence", "N", "First sequence number (default: 0)"),
            optional("duplicate-id-prefix", "PREFIX", "Artemis duplicate-detection ID prefix"),
            optional("payload-prefix", "PREFIX", "Message body prefix"),
            optional("payload-bytes", "N", "Exact UTF-8 message-body size (default: 256)"),
            optional("acknowledgement-ledger", "FILE", "Force-synchronized ledger of successful sends"));

    private static final List<Option> CONSUME_OPTIONS = List.of(
            required("expected-count", "N", "Number of unique messages expected"),
            optional("expected-start", "N", "First expected sequence number (default: 0)"),
            optional("max-messages", "N", "Maximum deliveries to receive"),
            optional("receive-timeout-seconds", "N", "Per-delivery timeout (default: 5)"),
            flag("disconnect-before-ack", "Close and recreate the consumer before acknowledgement"),
            optional("disconnect-limit", "N", "Maximum deliberate disconnects"));

    private CommandLine() {
    }

    static Command parse(String[] args) {
        if (args.length == 0) {
            throw new IllegalArgumentException("missing operation");
        }
        Operation operation = Operation.parse(args[0]);
        List<Option> operationOptions = operation == Operation.SEND ? SEND_OPTIONS : CONSUME_OPTIONS;
        Map<String, Option> allowed = optionsFor(operationOptions);
        Map<String, String> values = parseValues(args, allowed);
        validateRequired(allowed, values);

        Common common = new Common(
                Protocol.parse(values.get("protocol")),
                values.get("url"),
                values.get("destination"),
                values.getOrDefault("username", ""),
                values.getOrDefault("password", ""),
                values.getOrDefault("run-id", UUID.randomUUID().toString()),
                values.containsKey("output") ? Path.of(values.get("output")) : null,
                values.getOrDefault("id-prefix", "validation-"));

        if (operation == Operation.SEND) {
            return new SendCommand(
                    common,
                    nonNegativeLong(values, "start-sequence", 0),
                    positiveLong(values, "count"),
                    values.getOrDefault("duplicate-id-prefix", "validation-duplicate-"),
                    values.getOrDefault("payload-prefix", "deterministic"),
                    positiveInteger(values, "payload-bytes", 256),
                    values.containsKey("acknowledgement-ledger")
                            ? Path.of(values.get("acknowledgement-ledger"))
                            : null);
        }

        long expectedCount = positiveLong(values, "expected-count");
        boolean disconnectBeforeAck = booleanValue(values, "disconnect-before-ack", false);
        long defaultMax = Math.addExact(expectedCount, disconnectBeforeAck ? 1 : 0);
        return new ConsumeCommand(
                common,
                nonNegativeLong(values, "expected-start", 0),
                expectedCount,
                nonNegativeLong(values, "max-messages", defaultMax),
                Duration.ofSeconds(positiveLong(values, "receive-timeout-seconds", 5)),
                disconnectBeforeAck,
                nonNegativeLong(values, "disconnect-limit", disconnectBeforeAck ? 1 : 0));
    }

    static boolean isHelpRequest(String[] args) {
        return args.length == 0
                || (args.length == 1 && ("help".equals(args[0]) || "--help".equals(args[0])))
                || (args.length == 2
                && ("send".equals(args[0]) || "consume".equals(args[0]))
                && ("help".equals(args[1]) || "--help".equals(args[1])));
    }

    static String usage() {
        StringBuilder text = new StringBuilder();
        text.append("Usage:\n");
        text.append("  validation-client send --protocol openwire|amqp --url URL --destination QUEUE --count N [options]\n");
        text.append("  validation-client consume --protocol openwire|amqp --url URL --destination QUEUE --expected-count N [options]\n");
        appendOptions(text, "Common options", COMMON_OPTIONS);
        appendOptions(text, "Send options", SEND_OPTIONS);
        appendOptions(text, "Consume options", CONSUME_OPTIONS);
        return text.toString();
    }

    private static Map<String, Option> optionsFor(List<Option> operationOptions) {
        Map<String, Option> options = new LinkedHashMap<>();
        for (Option option : COMMON_OPTIONS) {
            options.put(option.name(), option);
        }
        for (Option option : operationOptions) {
            options.put(option.name(), option);
        }
        return options;
    }

    private static Map<String, String> parseValues(String[] args, Map<String, Option> allowed) {
        Map<String, String> values = new HashMap<>();
        for (int index = 1; index < args.length; index++) {
            String argument = args[index];
            if (!argument.startsWith("--")) {
                throw new IllegalArgumentException("unexpected argument: " + argument);
            }

            String token = argument.substring(2);
            int equals = token.indexOf('=');
            String name = equals >= 0 ? token.substring(0, equals) : token;
            String inlineValue = equals >= 0 ? token.substring(equals + 1) : null;
            Option option = allowed.get(name);
            if (option == null) {
                throw new IllegalArgumentException(
                        "unknown option for " + args[0] + ": --" + name);
            }
            if (values.containsKey(name)) {
                throw new IllegalArgumentException("duplicate option: --" + name);
            }

            if (option.flag()) {
                values.put(name, inlineValue == null ? "true" : inlineValue);
            } else if (inlineValue != null) {
                values.put(name, inlineValue);
            } else {
                if (index + 1 >= args.length || args[index + 1].startsWith("--")) {
                    throw new IllegalArgumentException("option requires a value: --" + name);
                }
                values.put(name, args[++index]);
            }
        }
        return values;
    }

    private static void validateRequired(Map<String, Option> allowed, Map<String, String> values) {
        List<String> missing = new ArrayList<>();
        for (Option option : allowed.values()) {
            if (option.required()
                    && (!values.containsKey(option.name()) || values.get(option.name()).isBlank())) {
                missing.add("--" + option.name());
            }
        }
        if (!missing.isEmpty()) {
            throw new IllegalArgumentException("missing required option " + String.join(", ", missing));
        }
    }

    private static boolean booleanValue(
            Map<String, String> values,
            String name,
            boolean defaultValue) {
        String value = values.get(name);
        if (value == null) {
            return defaultValue;
        }
        if ("true".equalsIgnoreCase(value)) {
            return true;
        }
        if ("false".equalsIgnoreCase(value)) {
            return false;
        }
        throw new IllegalArgumentException("--" + name + " must be true or false");
    }

    private static long positiveLong(Map<String, String> values, String name) {
        return positiveLong(values, name, Long.MIN_VALUE);
    }

    private static long positiveLong(
            Map<String, String> values,
            String name,
            long defaultValue) {
        String value = values.get(name);
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

    private static long nonNegativeLong(
            Map<String, String> values,
            String name,
            long defaultValue) {
        String value = values.get(name);
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

    private static int positiveInteger(
            Map<String, String> values,
            String name,
            int defaultValue) {
        long parsed = positiveLong(values, name, defaultValue);
        if (parsed > Integer.MAX_VALUE) {
            throw new IllegalArgumentException("--" + name + " is too large");
        }
        return (int) parsed;
    }

    private static void appendOptions(StringBuilder text, String heading, List<Option> options) {
        text.append('\n').append(heading).append(":\n");
        for (Option option : options) {
            String syntax = "  --" + option.name()
                    + (option.flag() ? "" : " " + option.valueName())
                    + (option.required() ? " (required)" : "");
            text.append(String.format("  %-43s %s%n", syntax.stripLeading(), option.description()));
        }
    }

    private static Option required(String name, String valueName, String description) {
        return new Option(name, valueName, description, true, false);
    }

    private static Option optional(String name, String valueName, String description) {
        return new Option(name, valueName, description, false, false);
    }

    private static Option flag(String name, String description) {
        return new Option(name, "", description, false, true);
    }

    sealed interface Command permits SendCommand, ConsumeCommand {
        Common common();
    }

    record Common(
            Protocol protocol,
            String url,
            String destination,
            String username,
            String password,
            String runId,
            Path output,
            String idPrefix) {
    }

    record SendCommand(
            Common common,
            long startSequence,
            long count,
            String duplicateIdPrefix,
            String payloadPrefix,
            int payloadBytes,
            Path acknowledgementLedger) implements Command {
    }

    record ConsumeCommand(
            Common common,
            long expectedStart,
            long expectedCount,
            long maxMessages,
            Duration receiveTimeout,
            boolean disconnectBeforeAck,
            long disconnectLimit) implements Command {
    }

    private record Option(
            String name,
            String valueName,
            String description,
            boolean required,
            boolean flag) {
    }
}
