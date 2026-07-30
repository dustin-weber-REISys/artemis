package org.example.artemis.validation;

import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;

/**
 * Append-only, force-synchronized producer acknowledgement ledger.
 *
 * <p>Each line is {@code sequence<TAB>message-id}. The file is intentionally
 * simple so a failure harness can observe progress while the producer runs.
 */
public final class AcknowledgementLedger implements AcknowledgementSink, AutoCloseable {
    private final FileChannel channel;

    private AcknowledgementLedger(FileChannel channel) {
        this.channel = channel;
    }

    public static AcknowledgementLedger open(Path path) throws Exception {
        Path absolute = path.toAbsolutePath();
        Path parent = absolute.getParent();
        if (parent != null) {
            Files.createDirectories(parent);
        }
        return new AcknowledgementLedger(FileChannel.open(
                absolute,
                StandardOpenOption.CREATE,
                StandardOpenOption.TRUNCATE_EXISTING,
                StandardOpenOption.WRITE));
    }

    @Override
    public synchronized void record(long sequence, String id) throws Exception {
        if (id.indexOf('\t') >= 0 || id.indexOf('\n') >= 0 || id.indexOf('\r') >= 0) {
            throw new IllegalArgumentException("acknowledgement ledger IDs cannot contain tabs or newlines");
        }
        byte[] encoded = (sequence + "\t" + id + System.lineSeparator())
                .getBytes(StandardCharsets.UTF_8);
        ByteBuffer buffer = ByteBuffer.wrap(encoded);
        while (buffer.hasRemaining()) {
            channel.write(buffer);
        }
        channel.force(false);
    }

    @Override
    public synchronized void close() throws Exception {
        channel.close();
    }
}
