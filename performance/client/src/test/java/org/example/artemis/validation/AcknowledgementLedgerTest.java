package org.example.artemis.validation;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

class AcknowledgementLedgerTest {
    @TempDir
    Path tempDir;

    @Test
    void writesOneForcedRecordPerAcknowledgedSend() throws Exception {
        Path ledgerPath = tempDir.resolve("nested/acknowledged.tsv");

        try (AcknowledgementLedger ledger = AcknowledgementLedger.open(ledgerPath)) {
            ledger.record(7, "message-7");
            ledger.record(8, "message-8");
        }

        assertEquals("7\tmessage-7\n8\tmessage-8\n", Files.readString(ledgerPath));
    }

    @Test
    void rejectsIdsThatWouldCorruptTheLedgerFormat() throws Exception {
        try (AcknowledgementLedger ledger =
                     AcknowledgementLedger.open(tempDir.resolve("acknowledged.tsv"))) {
            assertThrows(IllegalArgumentException.class, () -> ledger.record(1, "bad\tid"));
        }
    }
}
